struct Catalog::Entry
  include JSON::Serializable
  include Comparable(self)

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

  def mirror?(repo_ref : Repo::Ref) : Mirror?
    mirrors.find { |mirror| mirror.repo_ref == repo_ref }
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

  def <=>(other : self)
    repo_ref <=> other.repo_ref
  end
end
