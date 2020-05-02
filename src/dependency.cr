class Dependency
  enum Scope
    RUNTIME
    DEVELOPMENT

    def to_s(io : IO)
      io << to_s
    end

    def to_s : String
      super.downcase
    end
  end

  getter name : String
  getter spec : JSON::Any
  getter scope : Scope

  def initialize(@name : String, @spec : JSON::Any, @scope : Scope = :RUNTIME)
  end

  def repo_ref : Repo::Ref?
    if git = spec["git"]?
      # Treat git specially to detect URLs to registered resolvers like `git: https://github.com/crystal-lang/shards`
      return Repo::Ref.new(git.as_s)
    else
      Repo::RESOLVERS.each do |resolver|
        if url = spec[resolver]?
          return Repo::Ref.new(resolver, url.as_s)
        end
      end
    end
    # if dependency["path"]?
    #   # Can't resolve path dependency
    #   return nil
    # else
    #   # Can't find resolver for #{dependency}"
    # end
  end

  def resolvable? : Bool
    !repo_ref.nil?
  end

  def version_reference
    {"commit", "tag", "version", "branch"}.each do |key|
      if value = spec[key]?
        return {key, value}
      end
    end
  end

  def_equals_and_hash name, spec, scope
end
