require "yaml"
require "./repo"

module Catalog
  def self.each_category(catalog_location)
    unless File.directory?(catalog_location)
      raise "Can't read catalog at #{catalog_location}, directory does not exist."
    end
    found_a_file = false
    Dir.glob(File.join(catalog_location, "*.yml")).each do |filename|
      found_a_file = true
      File.open(filename) do |file|
        begin
          category = Category.from_yaml(file)
        rescue exc
          raise Exception.new("Failure reading catalog #{filename}", cause: exc)
        end

        yield category, File.basename(filename, ".yml")
      end
    end
    unless found_a_file
      raise "Catalog at #{catalog_location} is empty."
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

  struct Mirror
    include JSON::Serializable

    enum State
      MIRROR
      LEGACY
    end

    getter repo_ref : Repo::Ref
    property? state : State

    def initialize(@repo_ref : Repo::Ref, @state : State = :mirror)
    end

    def legacy?
      state.legacy?
    end

    def to_yaml(builder)
      builder.mapping do
        builder.scalar repo_ref.resolver
        builder.scalar repo_ref.url.to_s

        if legacy?
          builder.scalar "state"
          role.to_yaml(builder)
        end
      end
    end

    def self.new(ctx : YAML::ParseContext, node : YAML::Nodes::Node)
      unless node.is_a?(YAML::Nodes::Mapping)
        node.raise "Expected mapping, not #{node.class}"
      end

      repo_ref = nil
      state = nil

      YAML::Schema::Core.each(node) do |key, value|
        key = String.new(ctx, key)
        case key
        when "state"
          unless value.is_a?(YAML::Nodes::Scalar) && (state = State.parse?(value.value))
            raise %(unexpected value for key `state` in Category::Mirror mapping, allowed values: #{State.values})
          end
        else
          repo_ref = Entry.parse_repo_ref(ctx, key, value)

          unless repo_ref
            node.raise "unknown key: #{key} in Category::Mirror mapping"
          end
        end
      end

      unless repo_ref
        node.raise "missing required repo reference"
      end

      state ||= State::MIRROR
      new(repo_ref, state)
    end
  end

  struct Entry
    include JSON::Serializable

    enum State
      ACTIVE
      ARCHIVED

      def to_s(io : IO)
        io << to_s
      end

      def to_s
        super.downcase
      end

      def to_yaml(builder : YAML::Nodes::Builder)
        builder.scalar to_s
      end
    end

    getter repo_ref : Repo::Ref
    property description : String?
    getter mirror : Array(Repo::Ref)
    getter legacy : Array(Repo::Ref)
    getter categories : Array(String)
    property state : State

    def initialize(@repo_ref : Repo::Ref, @description : String? = nil,
                   @mirror = [] of Repo::Ref, @legacy = [] of Repo::Ref,
                   @state : State = :active, @categories = [] of String)
    end

    def archived? : Bool
      state.archived?
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

        if archived?
          builder.scalar "state"
          state.to_yaml(builder)
        end
      end
    end

    private def mirror_to_yaml(builder, list, name)
      unless list.empty?
        builder.scalar name
        builder.sequence do
          list.each do |ref|
            ref.to_json(builder)
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
      state = nil

      YAML::Schema::Core.each(node) do |key, value|
        key = String.new(ctx, key)
        case key
        when "description"
          description = String.new(ctx, value)
        when "mirror"
          mirror = Array(Mirror).new(ctx, value).map(&.repo_ref)
        when "legacy"
          legacy = Array(Mirror).new(ctx, value).map(&.repo_ref)
        when "state"
          unless value.is_a?(YAML::Nodes::Scalar) && (state = State.parse?(value.value))
            raise %(unexpected value for key `state` in Category::Entry mapping, allowed values: #{State.values})
          end
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

      state ||= State::ACTIVE
      new(repo_ref, description, mirror, legacy, state)
    end

    def self.parse_repo_ref(ctx : YAML::ParseContext, key, value)
      if key == "git"
        # Special case "git" to resolve URLs pointing at named service providers (like https://github.com/foo/foo)
        Repo::Ref.new(String.new(ctx, value))
      elsif Repo::RESOLVERS.includes?(key)
        Repo::Ref.new(key, String.new(ctx, value))
      end
    end
  end
end
