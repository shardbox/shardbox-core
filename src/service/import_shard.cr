require "taskmaster"
require "../db"
require "../repo"
require "../repo/resolver"
require "./sync_repo"
require "../shard"
require "raven"

struct Service::ImportShard
  include Taskmaster::Job

  def initialize(@repo_ref : Repo::Ref)
  end

  def perform
    ShardsDB.transaction do |db|
      import_shard(db)
    end
  end

  def import_shard(db)
    Raven.tags_context repo: @repo_ref.to_s

    import_shard(db, Repo::Resolver.new(@repo_ref))
  end

  def import_shard(db : ShardsDB, resolver : Repo::Resolver)
    repo_id = create_repo(db)
    shard_id = create_shard(db, resolver, repo_id)

    Service::SyncRepo.new(repo_id).perform_later

    shard_id
  end

  def import_shard(db : ShardsDB, repo_id : Int64)
    Raven.tags_context repo: @repo_ref.to_s

    resolver = Repo::Resolver.new(@repo_ref)

    shard_id = create_shard(db, resolver, repo_id)

    Service::SyncRepo.new(repo_id).perform_later

    shard_id
  end

  def create_shard(db : ShardsDB, resolver : Repo::Resolver, repo_id)
    begin
      spec_raw = resolver.fetch_raw_spec
    rescue Repo::Resolver::RepoUnresolvableError
      sync_failed(db, repo_id)

      Raven.send_event Raven::Event.new(
          level: :warning,
          message: "Failed to clone repository",
          tags: {
            repo: resolver.repo_ref.to_s,
            resolver: resolver.repo_ref.resolver
          }
        )

      return
    end

    unless spec_raw
      sync_failed(db, repo_id)

      raise "Repo HEAD misses shard.yml"
    end

    spec = Shards::Spec.from_yaml(spec_raw)

    shard_id = find_or_create_shard_by_name(db, spec.name)

    db.connection.exec <<-SQL, repo_id, shard_id
      UPDATE
        repos
      SET
        shard_id = $2,
        sync_failed_at = NULL
      WHERE
        id = $1 AND shard_id IS NULL
      SQL

    shard_id
  end

  def find_or_create_shard_by_name(db, shard_name) : Int64
    if shard_id = db.find_shard_id?(shard_name)
      # There is already a shard by that name. Need to check if it's the same one.

      if db.connection.query_one? <<-SQL, shard_id, @repo_ref.resolver, @repo_ref.url, as: {Bool}
        SELECT
          true
        FROM
          repos
        WHERE
          shard_id = $1 AND resolver = $2 AND url = $3
        SQL
        # Repo already linked
        return shard_id
      else
        # The repo could be a (legacy) mirror, a fork or simply a homonymous shard.
        # This is impossible to reliably detect automatically.
        # In essence, both forks and distinct shards need a separate Shard instance.
        # Mirrors should point to the same shard, but such a unification needs to
        # be manually reviewed.
        # For now, we treat it as a separate shard.

        # create shard with qualifier
        qualifier = find_qualifier(db, shard_name)

        return db.create_shard(Shard.new(shard_name, qualifier))
      end
    else
      # No other shard by that name, let's create it:
      return db.create_shard(Shard.new(shard_name))
    end
  end

  private def create_repo(db)
    repo = Repo.new(@repo_ref, nil, :canonical)
    db.create_repo(repo)
  end

  private def sync_failed(db, repo_id)
    db.connection.exec <<-SQL, repo_id
      UPDATE
        repos
      SET
        sync_failed_at = NOW()
      WHERE
        id = $1
      SQL
  end

  def find_qualifier(db, shard_name) : String
    url = URI.parse(@repo_ref.url)
    case @repo_ref.resolver
    when "github", "gitlab", "bitbucket"
      qualifier_parts = [File.dirname(url.path.not_nil!), @repo_ref.resolver].compact
    when "git"
      qualifier_parts = [url.host, File.dirname(url.path || "").gsub(/[^A-Za-z_\-.]+/, '-')].compact
    else
      raise "Unregcognized resolver #{@repo_ref.resolver}"
    end

    found = db.connection.query_one <<-SQL, shard_name, qualifier_parts[0], as: Int64
      SELECT
        COUNT(id)
      FROM shards
      WHERE
        name = $1 AND qualifier = $2
      SQL

    if found == 0
      qualifier_parts[0]
    else
      # The selected qualifier is already taken. Need to be more specific:
      qualifier_parts.join('-').gsub(/--+/, '-').strip('-')
    end
  end
end
