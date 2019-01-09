class Repo::Resolver
  def initialize(@resolver : MockResolver)
  end
end

class MockResolver
  alias MockEntry = {spec: String, revision_info: Release::RevisionInfo}

  def initialize(@versions : Hash(String, MockEntry) = {} of String => MockEntry)
  end

  def register(version : String, revision_info : Release::RevisionInfo, spec : String)
    @versions[version] = MockEntry.new(spec: spec, revision_info: revision_info)
  end

  def available_versions : Array(String)
    @versions.keys.compact
  end

  def spec(version : String? = nil)
    version ||= @versions.keys.last
    Shards::Spec.from_yaml(read_spec(version))
  end

  def read_spec(version : String? = nil)
    version ||= @versions.keys.last
    @versions[version][:spec]
  end

  def revision_info(version : String? = nil)
    version ||= @versions.keys.last
    @versions[version][:revision_info]
  end
end
