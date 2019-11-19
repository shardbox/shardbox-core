require "../db"
require "./sync_repo"

# This service synchronizes the information about a repository in the database.
struct Service::SyncRepos
  def initialize(@db : ShardsDB, @older_than : Time, @ratio : Float32)
  end

  def self.new(db, age : Time::Span = 24.hours, ratio : Number = 0.1)
    new(db, age.ago, ratio.to_f32)
  end

  def perform
    sync_repos
    sync_all_pending_repos
    update_shard_dependencies
  end

  def sync_all_pending_repos
    loop do
      pending = @db.repos_pending_sync
      break if pending.empty?
      pending.each do |repo|
        sync_repo(repo.ref)
      end
    end
  end

  def sync_repos
    repo_refs = @db.connection.query_all <<-SQL, @older_than, @ratio, as: {String, String}
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
        COALESCE(sync_failed_at, synced_at) ASC
      LIMIT (SELECT COUNT(*) FROM repos_update) * $2::real
      SQL

    repo_refs.each do |repo_ref|
      repo_ref = Repo::Ref.new(*repo_ref)
      sync_repo(repo_ref)
    end
  end

  def sync_repo(repo_ref)
    begin
      ShardsDB.transaction do |db|
        Service::SyncRepo.new(db, repo_ref).perform
      end
    rescue exc
      Raven.capture(exc)
    end
  end

  def update_shard_dependencies
    @db.connection.exec <<-SQL
      SELECT shard_dependencies_materialize()
    SQL
  end
end
