class Repo::Resolver
  def initialize(@resolver : MockResolver, @repo_ref)
  end
end

class MockResolver
  record MockEntry,
    spec : String?,
    revision_info : Release::RevisionInfo,
    files : Hash(String, String) = {} of String => String

  property? resolvable : Bool = true

  def self.new(versions : Hash(String, MockEntry) = {} of String => MockEntry)
    new(versions.transform_keys { |key| Shards::Version.new(key) })
  end

  def initialize(@versions : Hash(Shards::Version, MockEntry))
  end

  def self.unresolvable
    resolver = new
    resolver.resolvable = false
    resolver
  end

  def register(version : String, revision_info : Release::RevisionInfo, spec : String?)
    register(Shards::Version.new(version), revision_info, spec)
  end

  def register(version : Shards::Version, revision_info : Release::RevisionInfo, spec : String?)
    @versions[version] = MockEntry.new(spec, revision_info)
  end

  def available_releases : Array(Shards::Version)
    raise Repo::Resolver::RepoUnresolvableError.new unless resolvable?
    @versions.keys.compact.reject { |version| version.value == "HEAD" }
  end

  def spec(version : Shards::Version)
    raise Repo::Resolver::RepoUnresolvableError.new unless resolvable?
    Shards::Spec.from_yaml(read_spec(version))
  end

  def read_spec!(version : Shards::Version)
    raise Repo::Resolver::RepoUnresolvableError.new unless resolvable?
    @versions[version].spec
  end

  def revision_info(version : Shards::Version)
    raise Repo::Resolver::RepoUnresolvableError.new unless resolvable?
    @versions[version].revision_info
  end

  def latest_version_for_ref(ref)
    raise Repo::Resolver::RepoUnresolvableError.new unless resolvable?
    @versions.keys.last?
  end

  def fetch_file(version, path)
    raise Repo::Resolver::RepoUnresolvableError.new unless resolvable?
    @versions[version].files[path]?
  end
end

struct MockFetchMetadata
  def initialize(@metadata : Repo::Metadata?)
  end

  def fetch_repo_metadata
    if metadata = @metadata
      metadata
    else
      raise Shardbox::FetchError.new("Repo unavailable")
    end
  end
end
