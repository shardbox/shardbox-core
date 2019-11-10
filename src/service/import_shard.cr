require "taskmaster"
require "../db"
require "../repo"
require "../repo/resolver"
require "./sync_repo"
require "./update_shard"
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
    repo = create_repo(db)
    shard_id = create_shard(db, resolver, repo, entry)

    Service::SyncRepo.new(resolver.repo_ref).perform_later

    shard_id
  end

  def import_shard(db : ShardsDB, repo : Repo, entry : Catalog::Entry? = nil)
    import_shard(db, repo, Repo::Resolver.new(@repo_ref), entry)
  end

  def import_shard(db : ShardsDB, repo : Repo, resolver : Repo::Resolver, entry : Catalog::Entry? = nil)
    shard_id = repo.shard_id

    unless shard_id
      Raven.tags_context repo: @repo_ref.to_s, repo_id: repo.id

      shard_id = create_shard(db, resolver, repo, entry)

      Raven.tags_context repo: nil, repo_id: nil, shard_id: nil
    end

    Service::SyncRepo.new(@repo_ref).perform_later

    shard_id
  end

  def create_shard(db : ShardsDB, resolver : Repo::Resolver, repo : Repo, entry : Catalog::Entry? = nil)
    begin
      spec_raw = resolver.fetch_raw_spec
    rescue exc : Repo::Resolver::RepoUnresolvableError
      SyncRepo.sync_failed(db, repo, "fetch_spec_failed", exc.cause)

      return
    end

    unless spec_raw
      SyncRepo.sync_failed(db, repo, "spec_missing")

      return
    end

    spec = Shards::Spec.from_yaml(spec_raw)

    create_shard(db, repo, spec.name, entry)
  end

  def create_shard(db, repo, shard_name, entry) : Int64
    shard_id = find_or_create_shard_by_name(db, repo, shard_name, entry)

    db.connection.exec <<-SQL, repo.id, shard_id
      UPDATE
        repos
      SET
        shard_id = $2,
        role = 'canonical',
        sync_failed_at = NULL
      WHERE
        id = $1 AND shard_id IS NULL
      SQL

    shard_id
  end

  def find_or_create_shard_by_name(db, repo, shard_name, entry) : Int64
    if shard_id = repo.shard_id
      # The repo already existed and has a shard reference.

      # Update metadata
      Service::UpdateShard.new(shard_id, entry).perform(db)

      return shard_id
    end

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
      end
    else
      # No other shard by that name, let's create it
      qualifier = ""
    end

    shard_id = db.create_shard build_shard(shard_name, qualifier, entry)
    db.log_activity "import_shard:created", repo_id: repo.id, shard_id: shard_id

    shard_id
  end

  private def build_shard(shard_name, qualifier, entry)
    archived_at = nil
    if entry.try &.archived?
      archived_at = Time.utc
    end

    Shard.new(shard_name, qualifier, description: entry.try(&.description), archived_at: archived_at)
  end

  private def create_repo(db)
    if repo = db.get_repo?(@repo_ref)
      repo
    else
      repo = Repo.new(@repo_ref, nil, :canonical)
      repo_id = db.create_repo(repo)
      repo.id = repo_id
      db.log_activity "import_shard:repo:created", repo.id
      repo
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
      raise "Unrecognized resolver #{@repo_ref.resolver}"
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
