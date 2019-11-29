require "../db"
require "../repo"

# This service upserts a dependency.
class Service::SyncDependencies
  @version : String?
  @shard_id : Int64?

  def initialize(@db : ShardsDB, @release_id : Int64)
  end

  def sync_dependencies(dependencies : Array(Dependency))
    persisted_dependencies = query_dependencies

    persisted_dependencies.each do |persisted_dependency|
      new_dependency = dependencies.find { |d| d.name == persisted_dependency.name && d.scope == persisted_dependency.scope }
      if new_dependency
        if new_dependency != persisted_dependency
          update_dependency(new_dependency)
        end
      else
        remove_dependency(persisted_dependency)
      end
    end

    dependencies.each do |new_dependency|
      persisted_dependency = persisted_dependencies.find { |d| d.name == new_dependency.name && d.scope == new_dependency.scope }
      unless persisted_dependency
        add_dependency(new_dependency)
      end
    end
  end

  def add_dependency(dependency)
    repo_ref = dependency.repo_ref

    if repo_ref
      repo_id = upsert_repo(repo_ref)
    else
      repo_id = nil
    end

    dep_id = @db.connection.query_one? <<-SQL, @release_id, dependency.name, dependency.spec.to_json, dependency.scope, repo_id, as: Int64
      INSERT INTO dependencies
        (release_id, name, spec, scope, repo_id)
      VALUES
        ($1, $2, $3::jsonb, $4, $5)
      ON CONFLICT ON CONSTRAINT dependencies_uniq DO NOTHING
      RETURNING release_id
      SQL

    if dep_id.nil?
      # Insertion failed because a dependency with the same name exists already
      # for this release. It is probably a duplication of dev and runtime
      # dependencies.

      log("sync_dependencies:duplicate", dependency, repo_id)

      # Override previous if this is runtime dependency
      if dependency.scope.runtime?
        update_dependency(dependency)
      end

      return
    end

    log("sync_dependencies:created", dependency, repo_id)
  end

  def remove_dependency(dependency)
    @db.connection.exec <<-SQL, @release_id, dependency.name
      DELETE FROM
        dependencies
      WHERE
        release_id = $1 AND name = $2
      SQL

    if repo_ref = dependency.repo_ref
      repo_id = @db.get_repo_id?(repo_ref)
    else
      repo_id = nil
    end

    log("sync_dependencies:removed", dependency, repo_id)
  end

  def update_dependency(dependency)
    if repo_ref = dependency.repo_ref
      repo_id = @db.get_repo_id(repo_ref)
    else
      repo_id = nil
    end

    @db.connection.exec <<-SQL, @release_id, dependency.name, dependency.spec.to_json, dependency.scope, repo_id
      UPDATE dependencies SET
        spec = $3::jsonb,
        scope = $4,
        repo_id = $5
      WHERE
        release_id = $1 AND name = $2
      SQL

    log("sync_dependencies:updated", dependency, repo_id)
  end

  private def log(event, dependency, repo_id, metadata = nil)
    meta = {
      "release" => version,
      "name"    => dependency.name,
      "scope"   => dependency.scope.to_s,
    }
    if repo_id.nil?
      meta["repo_ref"] = dependency.repo_ref.to_s
    end

    if metadata
      meta.merge! metadata
    end
    @db.log_activity(event, repo_id, shard_id, meta)
  end

  private def version : String
    unless version = @version
      version = fetch_version_and_shard_id[0]
    end

    version
  end

  private def shard_id : Int64
    unless shard_id = @shard_id
      shard_id = fetch_version_and_shard_id[1]
    end

    shard_id
  end

  private def fetch_version_and_shard_id
    result = @db.connection.query_one("SELECT version, shard_id FROM releases WHERE id = $1", @release_id, as: {String, Int64})
    @version, @shard_id = result
    result
  end

  private def query_dependencies
    dependencies = @db.connection.query_all <<-SQL, @release_id, as: {String, JSON::Any, String}
      SELECT
        name::text, spec, scope::text
      FROM
        dependencies
      WHERE
        release_id = $1
      SQL

    dependencies.map do |name, spec, scope|
      Dependency.new(name, spec, Dependency::Scope.parse(scope))
    end
  end

  # Upserts repo and returns repo_id
  def upsert_repo(repo_ref : Repo::Ref)
    repo_id = @db.connection.query_one? <<-SQL, repo_ref.resolver, repo_ref.url, as: Int64?
      INSERT INTO repos
        (resolver, url)
      VALUES
        ($1, $2)
      ON CONFLICT ON CONSTRAINT repos_url_uniq DO NOTHING
      RETURNING id
      SQL

    repo_id || @db.get_repo_id(repo_ref)
  end
end
