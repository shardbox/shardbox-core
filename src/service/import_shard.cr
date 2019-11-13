require "../db"
require "../repo"
require "../repo/resolver"
require "./sync_repo"
require "./update_shard"
require "./create_shard"
require "../shard"

struct Service::ImportShard
  def initialize(@repo_ref : Repo::Ref)
  end

  def perform
    ShardsDB.transaction do |db|
      import_shard(db)
    end
  end

  # Entry point for ImportCatalog
  def import_shard(db : ShardsDB, repo : Repo? = nil, entry : Catalog::Entry? = nil, *, resolver = Repo::Resolver.new(@repo_ref))
    Raven.tags_context repo: @repo_ref.to_s

    repo ||= db.get_repo(@repo_ref)

    raise "Repo has already a shard associated" if repo.shard_id
    Raven.tags_context repo: @repo_ref.to_s, repo_id: repo.id

    spec = retrieve_spec(db, resolver, repo)
    return unless spec

    shard_id = CreateShard.new(db, repo, spec.name, entry).perform

    SyncRepo.new(@repo_ref).perform_later

    shard_id
  ensure
    Raven.tags_context repo: nil, repo_id: nil, shard_id: nil
  end

  private def retrieve_spec(db, resolver, repo)
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

    Shards::Spec.from_yaml(spec_raw)
  end
end
