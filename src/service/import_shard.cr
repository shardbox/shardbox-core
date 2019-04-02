require "taskmaster"
require "../db"
require "../repo"
require "../repo/resolver"
require "./sync_repo"
require "../shard"

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
    import_shard(db, Repo::Resolver.new(@repo_ref))
  end

  def import_shard(db : ShardsDB, resolver : Repo::Resolver)
    spec = resolver.fetch_spec

    shard_name = spec.name

    if shard_id = db.find_shard_id?(shard_name)
      # There is already a shard by that name. Need to check if it's the same one.

      if db.connection.query_one? <<-SQL, shard_id, @repo_ref.resolver, @repo_ref.url, as: {Bool}
        SELECT true
        FROM
          repos
        WHERE
          shard_id = $1 AND resolver = $2 AND url = $3
        SQL
        # Repo already exists, skip sync
        return
      else
        # The repo could be a (legacy) mirror, a fork or simply a homonymous shard.
        # This is impossible to reliably detect automatically.
        # In essence, both forks and distinct shards need a separate Shard instance.
        # Mirrors should point to the same shard, but such a unification needs to
        # be manually reviewed.
        # For now, we treat it as a separate shard.

        # create shard with qualifier
        qualifier = find_qualifier(db, shard_name)

        shard_id = db.create_shard(Shard.new(shard_name, qualifier, spec.description))

        create_repo(db, shard_id)
      end
    else
      # No other shard by that name, let's create it:
      shard = Shard.new(shard_name, description: spec.description)
      shard_id = db.create_shard(shard)

      create_repo(db, shard_id)
    end

    SyncRepo.new(shard_id).perform_later

    shard_id
  end

  private def create_repo(db, shard_id)
    repo = Repo.new(shard_id, @repo_ref, "canonical")
    db.create_repo(repo)
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
