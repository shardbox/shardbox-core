require "taskmaster"
require "../db"
require "../ext/yaml/any"
require "../repo/resolver"
require "../dependency"
require "raven"
require "../util/software_version"
require "./link_dependencies"
require "./import_shard"

# This service synchronizes the information about a release in the database.
class Service::SyncRelease
  include Taskmaster::Job

  def initialize(@shard_id : Int64, @version : String)
  end

  def perform
    ShardsDB.transaction do |db|
      repo = db.find_canonical_repo(@shard_id)
      resolver = Repo::Resolver.new(repo.ref)

      Raven.tags_context repo: repo.ref.to_s, version: @version

      sync_release(db, resolver)
    end
  end

  def sync_release(db, resolver)
    spec_raw = resolver.fetch_raw_spec(@version)

    if spec_raw
      spec = Shards::Spec.from_yaml(spec_raw)
      spec_json = JSON.parse(YAML.parse(spec_raw).to_json).as_h

      unless check_version_match(@version, spec.version)
        # TODO: What to do if spec reports different version than git tag?
        # Just stick with the tag version for now, because the spec version is not
        # really useable anyway.
        # raise "spec reports different version than tag: #{spec.version} - #{@version}"
        repo = resolver.repo_ref.to_s
        Raven.send_event Raven::Event.new(
            level: :warning,
            message: "Mismatching version tag from shards.yml, using tag version.",
            tags: {
              repo: repo,
              mismatch: "#{repo}@#{@version}: #{spec.version}",
              tag_version: @version,
              spec_version: spec.version,
            }
          )
      end
    else
      # No `shard.yml` found, using mock spec
      spec = Shards::Spec.from_yaml(%(name: #{resolver.repo_ref.name}\nversion: #{@version}))
      spec_json = {} of String => JSON::Any
    end

    revision_info = resolver.revision_info(@version)
    release = Release.new(@version, revision_info, spec_json)

    release_id = upsert_release(db, @shard_id, release)

    sync_dependencies(db, release_id, spec)

    LinkDependencies.new(release_id).perform(db)
  end

  def check_version_match(tag_version, spec_version)
    # quick check if versions match up
    return true if tag_version == spec_version

    # Accept any version in spec on HEAD (i.e. there is no tag version)
    return true if tag_version == "HEAD"

    # If versions are not identical, maybe they're noted differently.
    # Try parsing as SoftwareVersion
    return false unless SoftwareVersion.valid?(tag_version) && SoftwareVersion.valid?(spec_version)
    tag_version = SoftwareVersion.new(tag_version)
    spec_version = SoftwareVersion.new(spec_version)

    return true if tag_version == spec_version

    # We also accept versions tagged as pre-release having the release version
    # in the spec
    return true if tag_version.release == spec_version

    false
  end

  def upsert_release(db, shard_id : Int64, release : Release)
    release_id = db.connection.query_one?(<<-SQL, shard_id, release.version, as: Int64)
      SELECT id FROM releases WHERE shard_id = $1 AND version = $2
      SQL

    if release_id
      # update
      sql = <<-SQL
        UPDATE releases
        SET
          released_at = $2, revision_info = $3::jsonb, spec = $4::jsonb, yanked_at = NULL
        WHERE
          id = $1
        SQL

      db.connection.exec sql, release_id, release.released_at, release.revision_info.to_json, release.spec.to_json
    else
      # insert
      sql = <<-SQL
        INSERT INTO releases
          (shard_id, version, released_at, revision_info, spec)
        VALUES
          ($1, $2, $3, $4::jsonb, $5::jsonb)
        RETURNING id
        SQL

      release_id = db.connection.scalar(sql, shard_id, release.version, release.released_at, release.revision_info.to_json, release.spec.to_json).as(Int64)
    end

    release_id
  end

  def sync_dependencies(db, release_id, spec : Shards::Spec)
    dependencies = [] of Dependency
    spec.dependencies.each do |spec_dependency|
      dependencies << Dependency.from_spec(spec_dependency)
    end

    spec.development_dependencies.each do |spec_dependency|
      dependencies << Dependency.from_spec(spec_dependency, :development)
    end

    sync_dependencies(db, release_id, dependencies)
  end

  def sync_dependencies(db, release_id, dependencies : Enumerable(Dependency))
    dependencies.each do |dependency|
      db.upsert_dependency(release_id, dependency)
    end

    db.connection.exec <<-SQL, release_id, dependencies.map(&.name)
      DELETE FROM dependencies
      WHERE
        release_id = $1 AND name <> ALL($2)
      SQL
  end
end
