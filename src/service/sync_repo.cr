require "taskmaster"
require "../db"
require "../ext/yaml/any"
require "../repo/resolver"
require "./sync_release"
require "./order_releases"
require "raven"

# This service synchronizes the information about a repository in the database.
struct Service::SyncRepo
  include Taskmaster::Job

  def initialize(@repo_id : Int64)
  end

  def perform
    ShardsDB.transaction do |db|
      repo_ref = db.find_repo_ref(@repo_id)
      resolver = Repo::Resolver.new(repo_ref)

      Raven.tags_context repo: repo_ref.to_s

      sync_repo(db, resolver)
    end
  end

  def sync_repo(db, resolver : Repo::Resolver)
    repo = db.find_repo(resolver.repo_ref)
    shard_id = repo.shard_id

    unless shard_id
      shard_id = ImportShard.new(resolver.repo_ref).create_shard(db, resolver, @repo_id)

      return unless shard_id
    end

    if repo.role.canonical?
      # We only track releases on canonical repos

      begin
        sync_releases(db, resolver, shard_id)
      rescue Repo::Resolver::RepoUnresolvableError
        sync_failed(db)

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
    end

    sync_metadata(db, resolver)
  end

  def sync_releases(db, resolver, shard_id)
    versions = resolver.fetch_versions

    versions.each do |version|
      if !SoftwareVersion.valid?(version) && version != "HEAD"
        # TODO: What should happen when a version tag is invalid?
        # Ignoring for now.
        Raven.send_event Raven::Event.new(
            level: :warning,
            message: "Invalid version, ignoring release.",
            tags: {
              repo: resolver.repo_ref.to_s,
              tag_version: version
            }
          )
        next
      end

      SyncRelease.new(shard_id, version).sync_release(db, resolver)
    end

    yank_releases_with_missing_versions(db, shard_id, versions)

    Service::OrderReleases.new(shard_id).order_releases(db)
  end

  def yank_releases_with_missing_versions(db, shard_id, versions)
    db.connection.exec <<-SQL, shard_id, versions
      UPDATE
        releases
      SET
        yanked_at = NOW()
      WHERE
        shard_id = $1 AND yanked_at IS NULL AND version <> ALL($2)
      SQL
  end

  def sync_metadata(db, resolver)
    metadata = resolver.fetch_metadata
    metadata ||= JSON::Any.new(Hash(String, JSON::Any).new)

    db.connection.exec <<-SQL, @repo_id, metadata.to_json
      UPDATE
        repos
      SET
        synced_at = NOW(),
        sync_failed_at = NULL,
        metadata = $2::jsonb
      WHERE
        id = $1
      SQL
  end

  private def sync_failed(db)
    db.connection.exec <<-SQL, @repo_id
      UPDATE
        repos
      SET
        sync_failed_at = NOW()
      WHERE
        id = $1
      SQL
  end
end
