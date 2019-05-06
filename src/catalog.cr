require "yaml"
require "./repo"

module Catalog
  def self.each_category(catalog_location)
    Dir.glob(File.join(catalog_location, "*.yml")).each do |filename|
      File.open(filename) do |file|
        begin
          category = Category.from_yaml(file)
        rescue exc
          raise Exception.new("Failure reading catalog #{filename}", cause: exc)
        end

        yield category, File.basename(filename, ".yml")
      end
    end
  end

  class Category
    include YAML::Serializable

    getter name : String

    getter description : String?

    getter shards : Array(Entry) = [] of Catalog::Entry

    def initialize(@name : String, @description : String? = nil)
    end
  end

  struct Entry
    getter repo_ref : Repo::Ref
    getter description : String?
    getter mirror : Array(Repo::Ref)
    getter legacy : Array(Repo::Ref)
    getter categories : Array(String) = [] of String

    def initialize(@repo_ref : Repo::Ref, @description : String? = nil, @mirror = [] of Repo::Ref, @legacy = [] of Repo::Ref)
    end

    def to_yaml(builder : YAML::Nodes::Builder)
      builder.mapping do
        builder.scalar repo_ref.resolver
        builder.scalar repo_ref.url.to_s

        if description = @description
          builder.scalar "description"
          builder.scalar description
        end

        mirror_to_yaml(builder, mirror, "mirror")
        mirror_to_yaml(builder, legacy, "legacy")
      end
    end

    private def mirror_to_yaml(builder, list, name)
      unless list.empty?
        builder.scalar name
        builder.sequence do
          list.each do |ref|
            builder.scalar ref.resolver
            builder.scalar ref.url.to_s
          end
        end
      end
    end

    def self.new(ctx : YAML::ParseContext, node : YAML::Nodes::Node)
      unless node.is_a?(YAML::Nodes::Mapping)
        node.raise "Expected mapping, not #{node.class}"
      end

      description = nil
      repo_ref = nil
      mirror = [] of Repo::Ref
      legacy = [] of Repo::Ref
      YAML::Schema::Core.each(node) do |key, value|
        key = String.new(ctx, key)
        case key
        when "description"
          description = String.new(ctx, value)
        when "mirror"
          unless value.is_a?(YAML::Nodes::Sequence)
            raise "expected sequence for key `mirror` in Category::Entry mapping"
          end
          mirror = parse_mirror_or_legacy(ctx, value)
        when "legacy"
          unless value.is_a?(YAML::Nodes::Sequence)
            raise "expected sequence for key `legacy` in Category::Entry mapping"
          end
          legacy = parse_mirror_or_legacy(ctx, value)
        else
          repo_ref = parse_repo_ref(ctx, key, value)

          unless repo_ref
            node.raise "unknown key: #{key} in Category::Entry mapping"
          end
        end
      end

      unless repo_ref
        node.raise "missing required repo reference"
      end

      new(repo_ref, description, mirror, legacy)
    end

    private def self.parse_mirror_or_legacy(ctx, node)
      list = [] of Repo::Ref
      node.each do |child|
        unless child.is_a?(YAML::Nodes::Mapping)
          child.raise "Expected mapping, not #{child.class} in mirror entry"
        end
        YAML::Schema::Core.each(child) do |key, value|
          key = String.new(ctx, key)
          parsed_ref = parse_repo_ref(ctx, key, value)
          unless parsed_ref
            raise "unknown key: #{key} in mirror mapping"
          end
          list << parsed_ref
        end
      end
      list
    end

    private def self.parse_repo_ref(ctx, key, value)
      if key == "git"
        # Special case "git" to resolve URLs pointing at named service providers (like https://github.com/foo/foo)
        Repo::Ref.new(String.new(ctx, value))
      elsif Repo::RESOLVERS.includes?(key)
        Repo::Ref.new(key, String.new(ctx, value))
      end
    end
  end
end
