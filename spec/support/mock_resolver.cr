require "../../src/service/create_shard"

class Repo::Resolver
  def initialize(@resolver : MockResolver, @repo_ref)
  end
end

struct Service::ImportCatalog
  property mock_create_shard = false

  private def create_shard(entry, repo)
    if mock_create_shard
      # This avoids parsing shard spec in ImportShard
      Service::CreateShard.new(@db, repo, entry.repo_ref.name, entry).perform
    else
      previous_def
    end
  end
end

class MockResolver
  record MockEntry,
    spec : String?,
    revision_info : Release::RevisionInfo,
    files : Hash(String, String) = {} of String => String

  property? resolvable : Bool = true

  def initialize(@versions : Hash(String, MockEntry) = {} of String => MockEntry, @metadata : Repo::Metadata = Repo::Metadata.new)
  end

  def self.unresolvable
    resolver = new
    resolver.resolvable = false
    resolver
  end

  def register(version : String, revision_info : Release::RevisionInfo, spec : String?)
    @versions[version] = MockEntry.new(spec, revision_info)
  end

  def available_versions : Array(String)
    raise Repo::Resolver::RepoUnresolvableError.new unless resolvable?
    @versions.keys.compact
  end

  def spec(version : String? = nil)
    raise Repo::Resolver::RepoUnresolvableError.new unless resolvable?
    version ||= @versions.keys.last
    Shards::Spec.from_yaml(read_spec(version))
  end

  def read_spec(version : String? = nil)
    raise Repo::Resolver::RepoUnresolvableError.new unless resolvable?
    version ||= @versions.keys.last
    @versions[version].spec
  end

  def revision_info(version : String? = nil)
    raise Repo::Resolver::RepoUnresolvableError.new unless resolvable?
    version ||= @versions.keys.last
    @versions[version].revision_info
  end

  def fetch_metadata
    raise Repo::Resolver::RepoUnresolvableError.new unless resolvable?
    @metadata
  end

  def fetch_file(version, path)
    raise Repo::Resolver::RepoUnresolvableError.new unless resolvable?
    @versions[version].files[path]?
  end
end
