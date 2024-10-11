require "../catalog"

struct Service::CreateShard
  def initialize(@db : ShardsDB, @repo : Repo, @name : String, @entry : Catalog::Entry? = nil)
    raise "Repo has already a shard associated" if @repo.shard_id
    raise "Repo is not canonical" unless @repo.role.canonical?
  end

  def perform
    qualifier, shard_id = find_qualifier

    if shard_id
      # Re-taking an archived shard
      # TODO: Maybe this should instead create a new shard (new id) with the
      # archived shard's qualifier in order to isolate from previous shard
      # instance, which might have been a different one altogether.
      Service::UpdateShard.new(@db, shard_id, @entry).perform
    else
      # Create a new shard
      shard = build_shard(@name, qualifier)
      shard_id = @db.create_shard(shard)
      @db.log_activity "create_shard:created", repo_id: @repo.id, shard_id: shard_id
    end

    @db.connection.exec <<-SQL, @repo.id, shard_id
      UPDATE
        repos
      SET
        shard_id = $2,
        role = 'canonical',
        sync_failed_at = NULL
      WHERE
        id = $1 AND shard_id IS NULL
      SQL

    shard_id
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
  def find_qualifier : {String, Int64?}
    unavailable_qualifiers = [] of String
    qualifier, archived_shard_id = possible_qualifiers do |qualifier|
      next unless qualifier
      qualifier = normalize(qualifier)

      shard_id = @db.get_shard_id?(@name, qualifier)

      if shard_id
        shard = @db.get_shard(shard_id)
        if shard.archived_at
          # found an archived shard, re-taking it
          break qualifier, shard_id
        else
          unavailable_qualifiers << qualifier
        end
      else
        break qualifier, nil
      end
    end

    unless qualifier
      raise "No suitable qualifier found (#{unavailable_qualifiers.inspect})"
    end

    {qualifier, archived_shard_id}
  end

  # This method yields qualifiers for this shard in order of preference
  private def possible_qualifiers(&)
    # 1. No qualifier
    yield ""

    # 2. Find a username
    resolver = @repo.ref.resolver
    url = @repo.ref.url
    case resolver
    when "github", "gitlab", "bitbucket"
      org = File.dirname(url)
      yield org

      yield resolver

      yield "#{org}-#{resolver}"
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

    {nil, nil}
  end

  private def normalize(string)
    string.gsub(/[^A-Za-z_\-.]+/, '-').strip('-')
  end
end
