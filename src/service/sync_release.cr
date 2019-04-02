require "taskmaster"
require "../db"
require "../ext/yaml/any"
require "../repo/resolver"
require "../dependency"

# This service synchronizes the information about a release in the database.
class Service::SyncRelease
  include Taskmaster::Job

  def initialize(@shard_id : Int64, @version : String)
  end

  def perform
    ShardsDB.transaction do |db|
      repo = db.find_canonical_repo(@shard_id)
      resolver = Repo::Resolver.new(repo.ref)

      sync_release(db, resolver)
    end
  end

  def sync_release(db, resolver)
    spec = resolver.fetch_spec(@version)

    if spec.version != @version
      # TODO: What to do if spec reports different version than git tag?
      # Just stick with the tag version for now, because the spec version is not
      # really useable anyway.
      # raise "spec reports different version than tag: #{spec.version} - #{@version}"
    end

    revision_info = resolver.revision_info(@version)
    spec_json = JSON.parse(YAML.parse(resolver.fetch_raw_spec(@version)).to_json).as_h
    release = Release.new(@version, revision_info, spec_json)

    release_id = upsert_release(db, @shard_id, release)

    sync_dependencies(db, release_id, spec)

    LinkDependencies.new(release_id).perform(db)
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
