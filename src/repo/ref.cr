class Repo
  struct Ref
    include JSON::Serializable
    include Comparable(self)

    PROVIDER_RESOLVERS = {"github", "gitlab", "bitbucket"}

    getter resolver : String
    getter url : String

    def initialize(@resolver : String, @url : String)
      raise "Unknown resolver #{@resolver}" unless RESOLVERS.includes?(@resolver)
      if provider_resolver?
        raise "Invalid url for resolver #{@resolver}: #{@url.inspect}" unless @url =~ /^[A-Za-z0-9_\-.]{1,100}\/[A-Za-z0-9_\-.]{1,100}$/
      end
    end

    def self.new(url : String) : self
      new URI.parse(url)
    end

    def self.new(uri : URI) : self
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
      else
        # fall through
      end

      path = uri.path
      if path.nil? || path.empty? || path == "/"
        raise "Invalid url for resolver git: #{uri.to_s.inspect}"
      end

      new("git", uri.to_s)
    end

    def self.parse(string : String)
      PROVIDER_RESOLVERS.each do |resolver|
        if string.starts_with?(resolver)
          size = resolver.bytesize
          if string.byte_at(size) == ':'.ord
            size += 1
            return new(resolver, string.byte_slice(size, string.bytesize - size))
          end
        end
      end

      new(string)
    end

    # Returns `true` if `resolver` is any of `PROVIDER_RESOLVER`.
    def provider_resolver? : Bool
      PROVIDER_RESOLVERS.includes?(@resolver)
    end

    def to_uri : URI
      if provider_resolver?
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
      File.basename(uri.path).rchop('/').rchop(".git")
    end

    def owner
      if provider_resolver?
        Path.posix(url).dirname
      end
    end

    def nice_url
      return url if provider_resolver? || !resolvable?

      url.lstrip("https://").lstrip("http://").rstrip("/").rstrip(".git")
    end

    def slug
      if provider_resolver?
        "#{resolver}.com/#{url}"
      else
        nice_url
      end
    end

    def base_url_source(refname = nil)
      refname = normalize_refname(refname)

      case resolver
      when "bitbucket"
        url = to_uri
        url.path += "/src/#{refname}/"
        url
      when "github"
        url = to_uri
        url.path += "/tree/#{refname}/"
        url
      when "gitlab"
        # gitlab doesn't necessarily need the `-` component but they use it by default
        # and it seems reasonable to be safe of any ambiguities
        url = to_uri
        url.path += "/-/tree/#{refname}/"
        url
      else
        nil
      end
    end

    def base_url_raw(refname = nil)
      refname = normalize_refname(refname)

      case resolver
      when "github", "bitbucket"
        url = to_uri
        url.path += "/raw/#{refname}/"
        url
      when "gitlab"
        # gitlab doesn't necessarily need the `-` component but they use it by default
        # and it seems reasonable to be safe of any ambiguities
        url = to_uri
        url.path += "/-/raw/#{refname}/"
        url
      else
        nil
      end
    end

    private def normalize_refname(refname)
      case refname
      when Nil, "HEAD"
        "master"
      else
        refname
      end
    end

    def resolvable?
      provider_resolver? || url.starts_with?("http://") || url.starts_with?("https://")
    end

    def <=>(other : self)
      result = name.compare(other.name, case_insensitive: true)
      return result unless result == 0

      if provider_resolver? && other.provider_resolver?
        result = url.compare(other.url, case_insensitive: true)
        return result unless result == 0

        resolver <=> other.resolver
      else
        slug <=> other.slug
      end
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
end
