require "yaml"
require "./repo"
require "./category"

module Catalog
  class Error < Exception
  end

  def self.read(catalog_location)
    categories = Hash(String, ::Category).new
    entries = {} of Repo::Ref => Entry
    mirrors = Set(Repo::Ref).new

    each_category(catalog_location) do |yaml_category, slug|
      category = ::Category.new(slug, yaml_category.name, yaml_category.description)
      categories[category.slug] = category
      yaml_category.shards.each do |shard|
        if stored_entry = entries[shard.repo_ref]?
          stored_entry.mirrors.concat(shard.mirrors)
          stored_entry.categories << slug
        else
          shard.categories << slug
          entries[shard.repo_ref] = shard
        end

        if duplicate_repo = duplicate_mirror?(shard, mirrors, entries)
          raise Error.new("duplicate mirror #{duplicate_repo} in #{slug}")
        end
      end
    end

    return categories, entries.values
  end

  def self.duplicate_mirror?(shard, mirrors, entries)
    return shard.repo_ref if mirrors.includes?(shard.repo_ref)

    shard.mirrors.each do |mirror|
      if entries.has_key?(mirror.repo_ref) || !mirrors.add?(mirror.repo_ref)
        return mirror.repo_ref
      end
    end

    nil
  end

  def self.each_category(catalog_location)
    unless File.directory?(catalog_location)
      raise Error.new "Can't read catalog at #{catalog_location}, directory does not exist."
    end
    found_a_file = false

    filenames = Dir.glob(File.join(catalog_location, "*.yml")).sort
    filenames.each do |filename|
      found_a_file = true
      File.open(filename) do |file|
        begin
          category = Category.from_yaml(file)
        rescue exc
          raise Error.new("Failure reading catalog #{filename}", cause: exc)
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

    getter repo_ref : Repo::Ref
    getter role : Repo::Role = :mirror

    def initialize(@repo_ref : Repo::Ref, role : Repo::Role = :mirror)
      self.role = role
    end

    def legacy?
      role.legacy?
    end

    def role=(role : Repo::Role)
      raise "Invalid role for Catalog::Mirror: #{role}" if role.canonical?
      @role = role
    end

    def to_yaml(builder)
      builder.mapping do
        builder.scalar repo_ref.resolver
        builder.scalar repo_ref.url.to_s

        if legacy?
          builder.scalar "role"
          role.to_yaml(builder)
        end
      end
    end

    def self.new(ctx : YAML::ParseContext, node : YAML::Nodes::Node)
      unless node.is_a?(YAML::Nodes::Mapping)
        node.raise "Expected mapping, not #{node.class}"
      end

      repo_ref = nil
      role = nil

      YAML::Schema::Core.each(node) do |key, value|
        key = String.new(ctx, key)
        case key
        when "role"
          unless value.is_a?(YAML::Nodes::Scalar) && (role = Repo::Role.parse?(value.value)) && !role.canonical?
            raise %(unexpected value for key `role` in Category::Mirror mapping, allowed values: #{Repo::Role.values.delete(Repo::Role::CANONICAL)})
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

      role ||= Repo::Role::MIRROR
      new(repo_ref, role)
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
    getter mirrors : Array(Mirror)
    getter categories : Array(String)
    property state : State

    def initialize(@repo_ref : Repo::Ref, @description : String? = nil,
                   @mirrors = [] of Mirror,
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

        unless mirrors.empty?
          builder.scalar "mirrors"
          mirrors.to_yaml builder
        end

        if archived?
          builder.scalar "state"
          state.to_yaml(builder)
        end
      end
    end

    def self.new(ctx : YAML::ParseContext, node : YAML::Nodes::Node)
      unless node.is_a?(YAML::Nodes::Mapping)
        node.raise "Expected mapping, not #{node.class}"
      end

      description = nil
      repo_ref = nil
      mirrors = [] of Mirror
      state = nil

      YAML::Schema::Core.each(node) do |key, value|
        key = String.new(ctx, key)
        case key
        when "description"
          description = String.new(ctx, value)
        when "mirrors"
          mirrors += Array(Mirror).new(ctx, value)
        when "mirror"
          # Legacy fields, use `mirrors` instead
          # TODO: Remove compatibility later
          mirrors += Array(Mirror).new(ctx, value)
        when "legacy"
          # Legacy fields, use `mirrors` instead
          # TODO: Remove compatibility later
          array = Array(Mirror).new(ctx, value)
          array.map! { |mirror| mirror.role = :LEGACY; mirror }
          mirrors += array
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
      new(repo_ref, description, mirrors, state)
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
