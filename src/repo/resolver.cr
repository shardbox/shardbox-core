require "shards/logger"
require "shards/package"
require "../ext/shards/resolvers/git"

class Repo
  class Resolver
    def initialize(@resolver : Shards::GitResolver)
    end

    def self.new(repo : Repo::Ref)
      new(resolver_instance(repo))
    end

    def fetch_versions : Array(String)
      @resolver.available_versions
    end

    def fetch_spec(version : String? = nil)
      @resolver.spec(version)
    end

    def fetch_raw_spec(version : String? = nil)
      @resolver.read_spec(version)
    end

    def revision_info(version : String? = nil)
      @resolver.revision_info(version)
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
