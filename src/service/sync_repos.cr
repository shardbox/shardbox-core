require "taskmaster"
require "../db"
require "./sync_repo"
require "./update_dependencies"

# This service synchronizes the information about a repository in the database.
struct Service::SyncRepos
  include Taskmaster::Job

  def initialize(@older_than : Time, @ratio : Float32)
  end

  def self.new(age : Time::Span = 24.hours, ratio : Number = 0.1)
    new(age.ago, ratio.to_f32)
  end

  def perform
    ShardsDB.transaction do |db|
      sync_repos(db)

      UpdateDependencies.new.perform_later
    end
  end

  def sync_repos(db)
    repo_refs = db.connection.query_all <<-SQL, @older_than, @ratio, as: {String, String}
      WITH repos_update AS (
        SELECT
          id, resolver, url, shard_id, synced_at, sync_failed_at
        FROM
          repos
        WHERE
          (synced_at IS NULL OR synced_at < $1)
          AND (sync_failed_at IS NULL OR sync_failed_at < $1)
          AND role <> 'obsolete'
      )
      SELECT
        resolver::text, url::text
      FROM
        repos_update
      ORDER BY
        CASE WHEN(shard_id IS NULL) THEN 0 ELSE 1 END,
        sync_failed_at ASC NULLS FIRST,
        synced_at ASC NULLS FIRST
      LIMIT (SELECT COUNT(*) FROM repos_update) * $2::real
      SQL

    repo_refs.each do |repo_ref|
      repo_ref = Repo::Ref.new(*repo_ref)
      Service::SyncRepo.new(repo_ref).perform_later
    end
  end
end
