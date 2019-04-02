require "../db"
require "../repo"
require "taskmaster"

# This service tries to connect dependency references to already registered shards.
class Service::LinkDependencies
  include Taskmaster::Job

  def initialize(@release_id : Int64)
  end

  def perform
    ShardsDB.transaction do |db|
      perform(db)
    end
  end

  def perform(db)
    results = db.connection.query_all <<-SQL, @release_id, as: {Int64, String, JSON::Any, String}
      SELECT
        release_id, name::text, spec, scope::text
      FROM dependencies
      WHERE
        release_id = $1 AND shard_id IS NULL AND resolvable
      SQL

    results.each do |row|
      release_id, name, spec, scope = row

      dependency = Dependency.new(name, spec, Dependency::Scope.parse(scope))

      repo_ref = dependency.repo_ref

      unless repo_ref
        # No repo ref found: either local path resolver or invalid dependency
        db.connection.exec <<-SQL, @release_id, name
          UPDATE dependencies
          SET
            resolvable = false
          WHERE
            release_id = $1 AND name = $2
          SQL

        next
      end

      shard_id = db.connection.query_one? <<-SQL, repo_ref.resolver, repo_ref.url.to_s, as: Int64?
        SELECT
          shard_id
        FROM
          repos
        WHERE resolver = $1 AND url = $2
        SQL

      if shard_id
        # dependency is already registered as a shard
        db.connection.exec <<-SQL, @release_id, name, shard_id
          UPDATE dependencies
          SET
            shard_id = $3
          WHERE
            release_id = $1 AND name = $2
          SQL
      else
        # dependency repo needs to fetched

        ImportShard.new(repo_ref).perform_later
      end
    end
  end
end
