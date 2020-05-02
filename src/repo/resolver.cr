require "shards/logger"
require "shards/package"
require "../ext/shards/resolvers/git"
require "../ext/shards/resolvers/github"
require "../release"

struct Shards::Version
  def to_json(builder : JSON::Builder)
    value.to_json(builder)
  end
end

class Repo
  class Resolver
    class RepoUnresolvableError < Exception
    end

    getter repo_ref

    def initialize(@resolver : Shards::GitResolver, @repo_ref : Repo::Ref)
    end

    def self.new(repo_ref : Repo::Ref)
      new(resolver_instance(repo_ref), repo_ref)
    end

    def fetch_versions : Array(Shards::Version)
      @resolver.available_releases
    rescue exc : Shards::Error
      if exc.message.try &.starts_with?("Failed to clone")
        raise RepoUnresolvableError.new(cause: exc)
      else
        raise exc
      end
    end

    def fetch_raw_spec(version : Shards::Version = nil) : String?
      @resolver.read_spec!(version)
    rescue exc : Shards::Error
      if exc.message.try &.starts_with?("Failed to clone")
        raise RepoUnresolvableError.new(cause: exc)
      elsif exc.message =~ /Missing ".*:shard.yml" for/
        return
      else
        raise exc
      end
    end

    def fetch_file(version : Shards::Version?, path : String)
      @resolver.fetch_file(version, path)
    end

    def revision_info(version : Shards::Version? = nil) : Release::RevisionInfo
      @resolver.revision_info(version)
    end

    def fetch_metadata : Repo::Metadata?
      if (resolver = @resolver).responds_to?(:fetch_metadata)
        resolver.fetch_metadata
      end
    end

    def latest_version_for_ref(ref) : Shards::Version?
      @resolver.latest_version_for_ref(ref)
    end

    def self.resolver_instance(repo_ref)
      resolver_class = Shards::Resolver.find_class(repo_ref.resolver)
      unless resolver_class
        raise RepoUnresolvableError.new("Can't find a resolver for #{repo_ref}")
      end
      resolver = resolver_class.find_resolver(repo_ref.resolver, repo_ref.name, repo_ref.url)
      unless resolver.is_a?(Shards::GitResolver)
        raise RepoUnresolvableError.new("Invalid resolver #{resolver} for #{repo_ref}")
      end
      resolver
    end
  end
end
