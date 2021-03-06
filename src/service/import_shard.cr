require "../db"
require "../repo"
require "../repo/resolver"
require "./sync_repo"
require "./update_shard"
require "./create_shard"
require "../shard"

struct Service::ImportShard
  @resolver : Repo::Resolver

  class Error < Exception
    def initialize(@repo : Repo, cause = nil)
      super("import_shard failed for #{repo.ref}", cause: cause)
    end
  end

  def initialize(@db : ShardsDB, @repo : Repo, resolver : Repo::Resolver? = nil, @entry : Catalog::Entry? = nil)
    @resolver = resolver || Repo::Resolver.new(@repo.ref)
  end

  def perform
    import_shard
  rescue exc
    ShardsDB.transaction do |db|
      db.repo_sync_failed(@repo)
    end

    raise Error.new(@repo, cause: exc)
  end

  # Entry point for ImportCatalog
  def import_shard
    raise "Repo has already a shard associated" if @repo.shard_id

    spec = retrieve_spec
    return unless spec

    shard_name = spec.name
    unless Shard.valid_name?(shard_name)
      Log.notice &.emit("invalid shard name", repo: @repo.ref.to_s, shard_name: shard_name)
      SyncRepo.sync_failed(@db, @repo, "invalid shard name")
      return
    end

    CreateShard.new(@db, @repo, shard_name, @entry).perform
  end

  private def retrieve_spec
    begin
      version = @resolver.latest_version_for_ref(nil)
      unless version
        return
      end
      spec_raw = @resolver.fetch_raw_spec(version)
    rescue exc : Repo::Resolver::RepoUnresolvableError
      SyncRepo.sync_failed(@db, @repo, "fetch_spec_failed", exc.cause)

      return
    rescue exc : Shards::Error
      SyncRepo.sync_failed(@db, @repo, "shards_error", exc.cause)

      return
    end

    unless spec_raw
      SyncRepo.sync_failed(@db, @repo, "spec_missing")

      return
    end

    Shards::Spec.from_yaml(spec_raw)
  end
end
