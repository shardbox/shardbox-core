require "yaml"
require "./repo"

class Category
  include YAML::Serializable

  getter name : String

  getter description : String?

  getter shards : Array(Entry) = [] of Category::Entry

  def initialize(@name : String, @description : String? = nil)
  end

  struct Entry
    getter repo_ref : Repo::Ref
    getter description : String?

    def initialize(@repo_ref : Repo::Ref, @description : String? = nil)
    end

    def to_yaml(builder : YAML::Nodes::Builder)
      builder.mapping do
        builder.scalar repo_ref.resolver
        builder.scalar repo_ref.url.to_s

        if description = @description
          builder.scalar "description"
          builder.scalar description
        end
      end
    end

    def self.new(ctx : YAML::ParseContext, node : YAML::Nodes::Node)
      unless node.is_a?(YAML::Nodes::Mapping)
        node.raise "Expected mapping, not #{node.class}"
      end

      description = nil
      repo_ref = nil
      YAML::Schema::Core.each(node) do |key, value|
        key = String.new(ctx, key)
        case key
        when "description"
          description = String.new(ctx, value)
        when "git"
          # Special case "git" to resolve URLs pointing at named service providers (like https://github.com/foo/foo)
          repo_ref = Repo::Ref.new(String.new(ctx, value))
        else
          if Repo::RESOLVERS.includes?(key)
            repo_ref = Repo::Ref.new(key, String.new(ctx, value))
          else
            node.raise "unknown key: #{key} in Category::Entry mapping"
          end
        end
      end

      unless repo_ref
        node.raise "missing required repo reference"
      end

      new(repo_ref, description)
    end
  end
end
