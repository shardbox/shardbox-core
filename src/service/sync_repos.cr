require "../db"
require "./sync_repo"

# This service synchronizes the information about a repository in the database.
struct Service::SyncRepos
  Log = Shardbox::Log.for("service.sync_repos")

  def initialize(@db : ShardsDB, @older_than : Time, @ratio : Float32)
    @repo_refs_count = 0
    @failures_count = 0
    @pending_repos_count = 0
  end

  def self.new(db, age : Time::Span = 24.hours, ratio : Number = 0.1)
    new(db, age.ago, ratio.to_f32)
  end

  def perform
    elapsed = Time.measure do
      # 1. Sync repos that haven't been synced since @older_than
      sync_repos
      # 2. Sync new repos that have never been processed (newly discovered dependencies)
      sync_all_pending_repos
      # 3. Update dependency table
      update_shard_dependencies
    end

    @db.log_activity "sync_repos:finished", metadata: {
      older_than:          @older_than,
      ratio:               @ratio,
      elapsed_time:        elapsed.to_s,
      repo_refs_count:     @repo_refs_count,
      failures_count:      @failures_count,
      pending_repos_count: @pending_repos_count,
    }
  end

  def sync_all_pending_repos(limit : Int32? = nil)
    iteration = 0
    loop do
      iteration += 1
      pending = @db.repos_pending_sync
      break if pending.empty?
      if limit && pending.size > limit
        pending = pending.first(limit)
      end
      Log.debug { "Syncing pending repos (#{iteration}): #{pending.size}" }
      pending.each do |repo|
        sync_repo(repo.ref)
        @pending_repos_count += 1
      end
      Log.debug { "Done syncing pending repos (#{iteration}): #{pending.size}" }
      if limit
        return
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

    Log.debug { "Syncing #{repo_refs.size} repos" }
    repo_refs.each do |repo_ref|
      repo_ref = Repo::Ref.new(*repo_ref)
      sync_repo(repo_ref)
    end
    Log.debug { "Done syncing repos" }
    @repo_refs_count = repo_refs.size
  end

  def sync_repo(repo_ref)
    ShardsDB.transaction do |db|
      begin
        Service::SyncRepo.new(db, repo_ref).perform
      rescue exc
        Raven.capture(exc)
        Log.error(exception: exc) { "Failure while syncing repo #{repo_ref}" }
        @failures_count += 1
      end
    end
  end

  def update_shard_dependencies
    @db.connection.exec <<-SQL
      SELECT shard_dependencies_materialize()
    SQL
  end
end
