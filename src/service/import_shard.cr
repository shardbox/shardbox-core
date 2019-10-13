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
    Raven.tags_context repo: @repo_ref.to_s

    import_shard(db, Repo::Resolver.new(@repo_ref))
  end

  def import_shard(db : ShardsDB, resolver : Repo::Resolver, entry : Catalog::Entry? = nil)
    repo_id = create_repo(db)
    shard_id = create_shard(db, resolver, repo_id, entry)

    Service::SyncRepo.new(resolver.repo_ref).perform_later

    shard_id
  end

  def import_shard(db : ShardsDB, repo_id : Int64, entry : Catalog::Entry? = nil)
    import_shard(db, repo_id, Repo::Resolver.new(@repo_ref), entry)
  end

  def import_shard(db : ShardsDB, repo_id : Int64, resolver : Repo::Resolver, entry : Catalog::Entry? = nil)
    Raven.tags_context repo: @repo_ref.to_s, repo_id: repo_id

    shard_id = create_shard(db, resolver, repo_id, entry)

    Raven.tags_context shard_id: shard_id

    Service::SyncRepo.new(@repo_ref).perform_later

    Raven.tags_context repo: nil, repo_id: nil, shard_id: nil

    shard_id
  end

  def create_shard(db : ShardsDB, resolver : Repo::Resolver, repo_id, entry : Catalog::Entry? = nil)
    begin
      spec_raw = resolver.fetch_raw_spec
    rescue exc : Repo::Resolver::RepoUnresolvableError
      SyncRepo.sync_failed(db, Repo.new(resolver.repo_ref, nil, id: repo_id), "fetch_spec_failed", exc.cause)

      return
    end

    unless spec_raw
      SyncRepo.sync_failed(db, Repo.new(resolver.repo_ref, nil, id: repo_id), "spec_missing")

      return
    end

    spec = Shards::Spec.from_yaml(spec_raw)

    create_shard(db, repo_id, spec.name, entry)
  end

  def create_shard(db, repo_id, shard_name, entry)
    shard_id = find_or_create_shard_by_name(db, shard_name, entry)

    if (categories = entry.try(&.categories)) && !categories.empty?
      db.update_categorization(shard_id, categories)
    end

    db.connection.exec <<-SQL, repo_id, shard_id
      UPDATE
        repos
      SET
        shard_id = $2,
        sync_failed_at = NULL
      WHERE
        id = $1 AND shard_id IS NULL
      SQL

    db.sync_log repo_id, "synced", {"action" => "new_shard"}

    shard_id
  end

  def find_or_create_shard_by_name(db, shard_name, entry) : Int64
    if shard_id = db.get_shard_id?(shard_name, nil)
      # There is already a shard by that name. Need to check if it's the same one.

      if db.connection.query_one? <<-SQL, shard_id, @repo_ref.resolver, @repo_ref.url, as: {Bool}
        SELECT
          true
        FROM
          repos
        WHERE
          shard_id = $1 AND resolver = $2 AND url = $3 AND role = 'canonical'
        SQL
        # Repo already linked, don't need to create it

        # Update metadata
        Service::UpdateShard.new(shard_id, entry).perform(db)

        return shard_id
      else
        # The shard exists, but it has a different canonical repo.
        # The repo could be a (legacy) mirror, a fork or simply a homonymous shard.
        # This is impossible to reliably detect automatically.
        # In essence, both forks and distinct shards need a separate Shard instance.
        # Mirrors should point to the same shard, but such a unification needs to
        # be manually reviewed.
        # For now, we treat it as a separate shard.

        # create shard with qualifier
        qualifier = find_qualifier(db, shard_name)

        return db.create_shard build_shard(shard_name, qualifier, entry)
      end
    else
      # No other shard by that name, let's create it:
      return db.create_shard build_shard(shard_name, "", entry)
    end
  end

  private def build_shard(shard_name, qualifier, entry)

    Shard.new(shard_name, qualifier, description: entry.try(&.description))
  end

  private def create_repo(db)
    if repo = db.find_repo?(@repo_ref)
      repo.id
    else
      repo = Repo.new(@repo_ref, nil, :canonical)
      db.create_repo(repo)
    end
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
