require "../ext/yaml/any"
require "../repo/resolver"
require "./sync_release"
require "./order_releases"

# This service synchronizes the information about a repository in the database.
struct Service::SyncRepo
  def initialize(@db : ShardsDB, @repo_ref : Repo::Ref)
  end

  def perform
    resolver = Repo::Resolver.new(@repo_ref)

    sync_repo(resolver)
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
        SyncRepo.sync_failed(@db, repo, "clone_failed", exc)

        return
      end
    end

    sync_metadata(resolver, repo)
  end

  def sync_releases(resolver, shard_id)
    versions = resolver.fetch_versions

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
        self.class.sync_failed(@db, repo, "sync_release:failed", exc, {"version" => version})

        failed_versions << version
      end
    end

    versions -= failed_versions
    yank_releases_with_missing_versions(shard_id, versions)

    Service::OrderReleases.new(@db, shard_id).perform
  end

  def yank_releases_with_missing_versions(shard_id, versions)
    @db.connection.exec <<-SQL, shard_id, versions
      UPDATE
        releases
      SET
        yanked_at = NOW()
      WHERE
        shard_id = $1 AND yanked_at IS NULL AND version <> ALL($2)
      SQL
  end

  def sync_metadata(resolver, repo : Repo)
    begin
      metadata = resolver.fetch_metadata
    rescue exc : Shards::Error
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

  def self.sync_failed(db, repo : Repo, event, exc = nil, metadata = nil)
    db.connection.exec <<-SQL, repo.id
      UPDATE
        repos
      SET
        sync_failed_at = NOW()
      WHERE
        id = $1
      SQL

    metadata ||= {} of String => String
    if exc
      metadata.merge!({
        "exception" => exc.class.to_s,
        "message"   => exc.message.to_s,
      })
    end
    db.log_activity "sync_repo:#{event}", repo_id: repo.id, shard_id: repo.shard_id, metadata: metadata

    Raven.send_event Raven::Event.new(
      level: :warning,
      message: "Failed to clone repository",
      tags: {
        repo:     repo.ref.to_s,
        resolver: repo.ref.resolver,
      }
    )
  end
end
