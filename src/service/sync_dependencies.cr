require "../db"
require "../repo"
require "./sync_repo"

# This service upserts a dependency.
class Service::SyncDependencies
  def initialize(@release_id : Int64)
  end

  def sync_dependencies(db, dependencies : Array(Dependency))
    dependencies.each do |dependency|
      sync_dependency(db, dependency)
    end

    db.connection.exec <<-SQL, @release_id, dependencies.map(&.name)
      DELETE FROM
        dependencies
      WHERE
        release_id = $1 AND name <> ALL($2)
      SQL
  end

  def sync_dependency(db, dependency)
    repo_ref = dependency.repo_ref

    if repo_ref
      if upsert_repo(db, repo_ref)
        SyncRepo.new(repo_ref).perform_later
      end

      db.connection.exec <<-SQL, @release_id, dependency.name, dependency.spec.to_json, dependency.scope, repo_ref.resolver, repo_ref.url
        WITH lookup_repo_id AS (
          SELECT id FROM repos WHERE resolver = $5 AND url = $6 LIMIT 1
        )
        INSERT INTO dependencies
          (release_id, name, spec, scope, repo_id)
        VALUES
          ($1, $2, $3::jsonb, $4, (SELECT id FROM lookup_repo_id))
        ON CONFLICT ON CONSTRAINT dependencies_uniq
        DO UPDATE SET
          spec = $3::jsonb,
          scope = $4,
          repo_id = (SELECT id FROM lookup_repo_id)
        SQL
    else
      # No repo ref found: either local path resolver or invalid dependency
      db.connection.exec <<-SQL, @release_id, dependency.name, dependency.spec.to_json, dependency.scope
        INSERT INTO dependencies
          (release_id, name, spec, scope)
        VALUES
          ($1, $2, $3::jsonb, $4)
        ON CONFLICT ON CONSTRAINT dependencies_uniq
        DO UPDATE SET
          spec = $3::jsonb,
          scope = $4,
          repo_id = NULL
        SQL
    end
  end

  # Returns true if a new repo was inserted
  def upsert_repo(db, repo_ref : Repo::Ref)
    result = db.connection.query_one? <<-SQL, repo_ref.resolver, repo_ref.url, as: Int64?
      INSERT INTO repos
        (resolver, url)
      VALUES
        ($1, $2)
      ON CONFLICT ON CONSTRAINT repos_url_uniq DO NOTHING
      RETURNING id
      SQL
    !result.nil?
  end
end
