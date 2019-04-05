require "shards/logger"
require "shards/package"
require "../ext/shards/resolvers/git"
require "../../release"

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

    def fetch_versions : Array(String)
      @resolver.available_versions
    rescue exc : Shards::Error
      if exc.message.try &.starts_with?("Failed to clone")
        raise RepoUnresolvableError.new(cause: exc)
      else
        raise exc
      end
    end

    def fetch_raw_spec(version : String? = nil) : String?
      @resolver.read_spec(version)
    rescue exc : Shards::Error
      if exc.message.try &.starts_with?("Failed to clone")
        raise RepoUnresolvableError.new(cause: exc)
      elsif exc.message =~ /Missing ".*:shard.yml" for/
        return
      else
        raise exc
      end
    end

    def revision_info(version : String? = nil) : Release::RevisionInfo
      @resolver.revision_info(version)
    end

    def fetch_metadata : Hash(String, JSON::Any)?
      if (resolver = @resolver).responds_to?(:fetch_metadata)
        resolver.fetch_metadata
      end
    end

    def self.resolver_instance(repo_ref)
      dependency = Shards::Dependency.new(repo_ref.name)

      url = URI.parse(repo_ref.url)
      #  TODO: Remove when URI behaves properly
      if repo_ref.resolver == "git" && url.scheme == "file" && (path = url.opaque)
        url = url.dup
        url.opaque = nil
        url.path = File.expand_path(path)
      end

      dependency[repo_ref.resolver] = url.to_s

      Shards.find_resolver(dependency).as(Shards::GitResolver)
    end
  end
end
