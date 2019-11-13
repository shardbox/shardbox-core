struct Catalog::Mirror
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
