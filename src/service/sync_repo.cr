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

  def initialize(@shard_id : Int64)
  end

  def perform
    ShardsDB.transaction do |db|
      repo = db.find_canonical_repo(@shard_id)
      resolver = Repo::Resolver.new(repo.ref)

      Raven.tags_context repo: repo.ref.to_s

      sync_repo(db, resolver)
    end
  end

  def sync_repo(db, resolver : Repo::Resolver)
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

      SyncRelease.new(@shard_id, version).sync_release(db, resolver)
    end

    yank_releases_with_missing_versions(db, versions)

    Service::OrderReleases.new(@shard_id).order_releases(db)

    sync_metadata(db, resolver)
  end

  def yank_releases_with_missing_versions(db, versions)
    db.connection.exec <<-SQL, @shard_id, versions
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

    db.connection.exec <<-SQL, @shard_id, metadata.to_json
      UPDATE
        repos
      SET
        synced_at = NOW(),
        metadata = $2::jsonb
      WHERE
        shard_id = $1 AND role = 'canonical'
      SQL
  end
end
