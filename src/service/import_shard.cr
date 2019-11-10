require "taskmaster"
require "../db"
require "../repo"
require "../repo/resolver"
require "./sync_repo"
require "./update_shard"
require "./create_shard"
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
    repo = find_or_create_repo(db)
    shard_id = create_shard(db, resolver, repo, entry)

    Service::SyncRepo.new(@repo_ref).perform_later

    shard_id
  end

  # Entry point for ImportCatalog
  def import_shard(db : ShardsDB, repo : Repo, entry : Catalog::Entry? = nil)
    raise "Repo has already a shard associated" if repo.shard_id

    resolver = Repo::Resolver.new(@repo_ref)
    shard_id = create_shard(db, resolver, repo, entry)

    Service::SyncRepo.new(@repo_ref).perform_later

    shard_id
  end

  def create_shard(db : ShardsDB, resolver : Repo::Resolver, repo : Repo, entry : Catalog::Entry? = nil)
    Raven.tags_context repo: @repo_ref.to_s, repo_id: repo.id

    spec = retrieve_spec(db, resolver, repo)
    return unless spec

    CreateShard.new(db, repo, spec.name, entry).perform
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

  private def find_or_create_repo(db)
    if repo = db.get_repo?(@repo_ref)
      repo
    else
      repo = Repo.new(@repo_ref, nil, :canonical)
      repo.id = db.create_repo(repo)
      db.log_activity "import_shard:repo:created", repo.id
      repo
    end
  end
end
