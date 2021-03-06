require "../ext/yaml/any"
require "../repo/resolver"
require "./sync_release"
require "./order_releases"
require "./fetch_metadata"
require "./create_owner"

# This service synchronizes the information about a repository in the database.
struct Service::SyncRepo
  def initialize(@db : ShardsDB, @repo_ref : Repo::Ref)
  end

  Log = Shardbox::Log.for("service.sync_repo")

  def perform
    Log.debug { "Sync repo #{@repo_ref}" }

    duration = Time.measure do
      resolver = Repo::Resolver.new(@repo_ref)

      sync_repo(resolver)
    end

    Log.debug { "Done sync repo #{@repo_ref} in #{duration}" }
  end

  def sync_repo(resolver : Repo::Resolver)
    Raven.tags_context repo: @repo_ref.to_s
    repo = @db.get_repo(resolver.repo_ref)
    shard_id = repo.shard_id

    unless shard_id
      shard_id = ImportShard.new(@db, repo, resolver).perform

      return unless shard_id
    end

    if repo.role.canonical?
      # We only track releases on canonical repos

      begin
        sync_releases(resolver, shard_id)
      rescue exc : Repo::Resolver::RepoUnresolvableError
        SyncRepo.sync_failed(@db, repo, "clone_failed", exc.cause)

        return
      rescue exc : Shards::ParseError
        SyncRepo.sync_failed(@db, repo, "spec_invalid", exc, tags: {"error_message" => exc.message})

        return
      end
    end

    sync_metadata(repo)

    sync_owner(repo)
  end

  def sync_releases(resolver, shard_id)
    versions = resolver.fetch_versions

    if versions.empty?
      versions = ["HEAD"]
    end

    failed_versions = [] of String
    versions.each do |version|
      if !SoftwareVersion.valid?(version) && version != "HEAD"
        # TODO: What should happen when a version tag is invalid?
        # Ignoring this release for now and sending a note to sentry.

        Raven.send_event Raven::Event.new(
          level: :warning,
          message: "Invalid version, ignoring release.",
          tags: {
            repo:        resolver.repo_ref.to_s,
            tag_version: version,
          }
        )
        next
      end

      begin
        SyncRelease.new(@db, shard_id, version).sync_release(resolver)
      rescue exc : Shards::ParseError
        repo = @db.get_repo(resolver.repo_ref)
        SyncRepo.sync_failed(@db, repo, "sync_release:failed", exc, tags: {"error_message" => exc.message, "version" => version})

        failed_versions << version
      end
    end

    versions -= failed_versions
    yank_releases_with_missing_versions(shard_id, versions)

    Service::OrderReleases.new(@db, shard_id).perform
  end

  def yank_releases_with_missing_versions(shard_id, versions)
    yanked = @db.connection.query_all <<-SQL, shard_id, versions, as: String
      SELECT
        version
      FROM
        releases
      WHERE
        shard_id = $1 AND yanked_at IS NULL AND version <> ALL($2)
      ORDER BY position
      SQL

    @db.connection.exec <<-SQL, yanked
      UPDATE
        releases
      SET
        yanked_at = NOW()
      WHERE
        version = ANY($1)
      SQL

    yanked.each do |version|
      @db.log_activity("sync_repo:release:yanked", nil, shard_id, {"version" => version})
    end
  end

  def sync_metadata(repo : Repo, *, fetch_service = Service::FetchMetadata.new(repo.ref))
    begin
      metadata = fetch_service.fetch_repo_metadata
    rescue exc : Shardbox::FetchError
      SyncRepo.sync_failed(@db, repo, "fetch_metadata_failed", exc)

      return
    end

    metadata ||= Repo::Metadata.new

    @db.connection.exec <<-SQL, repo.id, metadata.to_json
      UPDATE
        repos
      SET
        synced_at = NOW(),
        sync_failed_at = NULL,
        metadata = $2::jsonb
      WHERE
        id = $1
      SQL

    @db.log_activity "sync_repo:synced", repo_id: repo.id
  end

  def sync_owner(repo, *, service = CreateOwner.new(@db, repo.ref))
    unless @db.get_owner?(repo.ref)
      service.perform
    end
  end

  def self.log_sync_failed(repo : Repo, event, exc = nil, metadata = nil)
    # Log failure in a separate connection because the main transaction
    # has already failed and won't be committed.
    ShardsDB.transaction do |db|
      log_sync_failed(db, repo, event, exc, metadata)
    end
  end

  def self.log_sync_failed(db, repo : Repo, event, exc = nil, metadata = nil)
    db.repo_sync_failed(repo)

    metadata ||= {} of String => String
    metadata["repo_role"] ||= repo.role.to_s
    db.log_activity "sync_repo:#{event}", repo_id: repo.id, shard_id: repo.shard_id, metadata: metadata, exc: exc
  rescue exc : PQ::PQError
    Shardbox::Log.trace(exception: exc) { "Secondary db error in log_sync_failed" }
    # ignore secondary DB error
  end

  def self.sync_failed(db, repo : Repo, event, exc = nil, tags = nil)
    log_sync_failed(db, repo, event, exc, tags)

    tags ||= {} of String => String
    tags["repo_role"] ||= repo.role.to_s

    if exc
      tags["exception"] ||= exc.class.to_s
      tags["error_message"] ||= exc.to_s
    end

    tags["repo"] ||= repo.ref.to_s
    tags["event"] ||= event

    Raven.send_event Raven::Event.new(
      level: :warning,
      message: "Failed to sync repository",
      tags: tags
    )
  end
end
