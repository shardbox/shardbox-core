require "../db"
require "../ext/yaml/any"
require "../repo/resolver"
require "../dependency"
require "../util/software_version"
require "./sync_dependencies"
require "./import_shard"

# This service synchronizes the information about a release in the database.
class Service::SyncRelease
  def initialize(@db : ShardsDB, @shard_id : Int64, @version : String)
  end

  def perform
    repo = @db.find_canonical_repo(@shard_id)
    resolver = Repo::Resolver.new(repo.ref)

    Raven.tags_context repo: repo.ref.to_s, version: @version

    sync_release(resolver)
  end

  def sync_release(resolver)
    release, spec = get_spec(resolver)

    release_id = upsert_release(@shard_id, release)

    sync_dependencies(release_id, spec)
    sync_files(release_id, resolver)
    sync_repos_stats(release_id, resolver)
  end

  def get_spec(resolver)
    spec_raw = resolver.fetch_raw_spec(@version)

    if spec_raw
      spec = Shards::Spec.from_yaml(spec_raw)
      spec_json = JSON.parse(YAML.parse(spec_raw).to_json).as_h
    else
      # No `shard.yml` found, using mock spec
      spec = Shards::Spec.from_yaml(%(name: #{@db.get_shard(@shard_id).name}\nversion: #{@version}))
      spec_json = {} of String => JSON::Any
    end

    # We're always using the tagged version as identifier (@version), which
    # might be different from the version reported in the spec (spec.version).
    # This is certainly unexpected but actually not a huge issue, we can just
    # accept this.
    # These mismatching releases can be queried from the database:
    #    SELECT version, spec->>'version' FROM releases WHERE version != spec->>'version'
    revision_info = resolver.revision_info(@version)
    release = Release.new(@version, revision_info, spec_json)

    return release, spec
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

  def upsert_release(shard_id : Int64, release : Release)
    release_id = @db.connection.query_one?(<<-SQL, shard_id, release.version, as: Int64)
      SELECT id FROM releases WHERE shard_id = $1 AND version = $2
      SQL

    if release_id
      # update
      release.id = release_id
      @db.update_release(release)
    else
      # insert
      release_id = @db.create_release(shard_id, release)
      @db.log_activity("sync_release:created", nil, shard_id, {"version" => release.version})
    end

    release_id
  end

  def sync_dependencies(release_id, spec : Shards::Spec)
    dependencies = [] of Dependency
    spec.dependencies.each do |spec_dependency|
      dependencies << Dependency.from_spec(spec_dependency)
    end

    spec.development_dependencies.each do |spec_dependency|
      dependencies << Dependency.from_spec(spec_dependency, :development)
    end

    SyncDependencies.new(@db, release_id).sync_dependencies(dependencies)
  end

  def sync_repos_stats(release_id, resolver)
  end

  README_NAMES = ["README.md", "Readme.md"]

  def sync_files(release_id, resolver)
    found = README_NAMES.each do |name|
      if content = resolver.fetch_file(@version, name)
        @db.put_file(release_id, README_NAMES.first, content)
        break true
      end
    end
    unless found
      @db.delete_file(release_id, README_NAMES.first)
    end
  end
end
