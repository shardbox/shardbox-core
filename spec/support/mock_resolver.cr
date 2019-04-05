class Repo::Resolver
  def initialize(@resolver : MockResolver, @repo_ref)
  end
end

class MockResolver
  alias MockEntry = {spec: String?, revision_info: Release::RevisionInfo}

  property? resolvable : Bool = true

  def initialize(@versions : Hash(String, MockEntry) = {} of String => MockEntry, @metadata : Hash(String, JSON::Any) = {} of String => JSON::Any)
  end

  def self.unresolvable
    resolver = new
    resolver.resolvable = false
    resolver
  end

  def register(version : String, revision_info : Release::RevisionInfo, spec : String?)
    @versions[version] = MockEntry.new(spec: spec, revision_info: revision_info)
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
    @versions[version][:spec]
  end

  def revision_info(version : String? = nil)
    raise Repo::Resolver::RepoUnresolvableError.new unless resolvable?
    version ||= @versions.keys.last
    @versions[version][:revision_info]
  end

  def fetch_metadata
    raise Repo::Resolver::RepoUnresolvableError.new unless resolvable?
    @metadata
  end
end
