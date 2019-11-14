require "../db"
require "../repo"
require "../repo/resolver"
require "./sync_repo"
require "./update_shard"
require "./create_shard"
require "../shard"

struct Service::ImportShard
  @resolver : Repo::Resolver

  def initialize(@db : ShardsDB, @repo : Repo, resolver : Repo::Resolver? = nil, @entry : Catalog::Entry? = nil)
    @resolver = resolver || Repo::Resolver.new(@repo.ref)
  end

  def perform
    import_shard
  end

  # Entry point for ImportCatalog
  def import_shard
    Raven.tags_context repo: @repo.ref.to_s

    raise "Repo has already a shard associated" if @repo.shard_id
    Raven.tags_context repo: @repo.ref.to_s, repo_id: @repo.id

    spec = retrieve_spec
    return unless spec

    CreateShard.new(@db, @repo, spec.name, @entry).perform
  ensure
    Raven.tags_context repo: nil, repo_id: nil, shard_id: nil
  end

  private def retrieve_spec
    begin
      spec_raw = @resolver.fetch_raw_spec
    rescue exc : Repo::Resolver::RepoUnresolvableError
      SyncRepo.sync_failed(@db, @repo, "fetch_spec_failed", exc.cause)

      return
    end

    unless spec_raw
      SyncRepo.sync_failed(@db, @repo, "spec_missing")

      return
    end

    Shards::Spec.from_yaml(spec_raw)
  end
end
