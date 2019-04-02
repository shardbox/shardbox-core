struct Repo::Ref
  include JSON::Serializable

  PROVIDER_RESOLVERS = {"github", "gitlab", "bitbucket"}

  getter resolver : String
  getter url : String

  def initialize(@resolver : String, @url : String)
    raise "Unknown resolver #{@resolver}" unless RESOLVERS.includes?(@resolver)
    if PROVIDER_RESOLVERS.includes?(@resolver)
      raise "Invalid url for resolver #{@resolver}: #{@url.inspect}" unless @url =~ /^[A-Za-z0-9_\-.]{1,100}\/[A-Za-z0-9_\-.]{1,100}$/
    end
  end

  def self.new(url : String)
    new URI.parse(url)
  end

  def self.new(uri : URI)
    case uri.host
    when "github.com", "www.github.com"
      if path = extract_org_repo_url(uri)
        return new("github", path)
      end
    when "gitlab.com", "www.gitlab.com"
      if path = extract_org_repo_url(uri)
        return new("gitlab", path)
      end
    when "bitbucket.com", "www.bitbucket.com"
      if path = extract_org_repo_url(uri)
        return new("bitbucket", path)
      end
    end

    new("git", uri.to_s)
  end

  def to_uri : URI
    if PROVIDER_RESOLVERS.includes?(@resolver)
      # FIXME: Leading slash should not be needed
      URI.new("https", "#{resolver}.com", path: "/#{url}")
    else
      URI.parse(url)
    end
  end

  private def self.extract_org_repo_url(uri)
    path = uri.path.not_nil!.strip('/').rchop(".git")
    if path.count('/') == 1
      path
    end
  end

  def_equals_and_hash resolver, url

  def name
    uri = URI.parse(url)
    File.basename((uri.path || uri.opaque).not_nil!).rchop('/').rchop(".git")
  end

  def to_s(io : IO)
    io << resolver
    io << ":"
    @url.dump_unquoted(io)
  end

  def inspect(io : IO)
    io << "#<Repo::Ref "
    to_s(io)
    io << ">"
  end
end
