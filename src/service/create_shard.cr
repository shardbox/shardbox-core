struct Service::CreateShard
  def initialize(@db : ShardsDB, @repo : Repo, @name : String, @entry : Catalog::Entry? = nil)
    raise "Repo has already a shard associated" if @repo.shard_id
    raise "Repo is not canonical" unless @repo.role.canonical?
  end

  def perform
    qualifier = find_qualifier

    shard = build_shard(@name, qualifier)
    shard.id = @db.create_shard(shard)
    @db.log_activity "import_shard:created", repo_id: @repo.id, shard_id: shard.id

    @db.connection.exec <<-SQL, @repo.id, shard.id
      UPDATE
        repos
      SET
        shard_id = $2,
        role = 'canonical',
        sync_failed_at = NULL
      WHERE
        id = $1 AND shard_id IS NULL
      SQL

    shard.id
  end

  private def build_shard(shard_name, qualifier)
    archived_at = nil
    if @entry.try &.archived?
      archived_at = Time.utc
    end

    Shard.new(shard_name, qualifier,
      description: @entry.try(&.description),
      archived_at: archived_at)
  end

  # Try to find a suitable shard name + qualifier.
  # If there is already a shard by that name, the repo could reasonable be a
  # mirror, a fork or simply a homonymous shard.
  # This is impossible to reliably detect automatically.
  # In essence, both forks and distinct shards need a separate shard instance.
  # Mirrors should point to the same shard, but such a unification needs to
  # be manually reviewed.
  private def find_qualifier : String
    unavailable_qualifiers = [] of String
    qualifier = possible_qualifiers do |qualifier|
      next unless qualifier
      qualifier = normalize(qualifier)
      if @db.get_shard_id?(@name, qualifier)
        unavailable_qualifiers << qualifier
      else
        break qualifier
      end
    end

    unless qualifier
      raise "No suitable qualifier found (#{unavailable_qualifiers.inspect})"
    end

    qualifier
  end

  # This method yields qualifiers for this shard in order of preference
  private def possible_qualifiers
    # 1. No qualifier
    yield ""

    # 2. Find a username
    resolver = @repo.ref.resolver
    url = @repo.ref.url
    case resolver
    when "github", "gitlab", "bitbucket"
      yield File.dirname(url)
    when "git"
      # If path looks like <username>/<repo> pattern
      uri = URI.parse(url)
      parents = Path.posix(uri.path).parents
      if parents.size == 2
        yield parents[-1].to_s
      end

      yield uri.host
    else
      raise "unreachable"
    end

    # 3. Repo name (if different from shard name)
    repo_name = @repo.ref.name
    if repo_name != @name
      yield repo_name
    end

    nil
  end

  private def normalize(string)
    string.gsub(/[^A-Za-z_\-.]+/, '-').strip('-')
  end
end
