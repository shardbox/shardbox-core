require "spec"
require "../../src/service/sync_repo"
require "../support/db"
require "../support/mock_resolver"

describe Service::SyncRepo do
  describe "#sync_repo" do
    it "handles unresolvable repo" do
      transaction do |db|
        repo_ref = Repo::Ref.new("git", "foo")
        repo_id = Factory.create_repo(db, repo_ref)
        service = Service::SyncRepo.new(repo_id)

        resolver = Repo::Resolver.new(MockResolver.unresolvable, repo_ref)
        service.sync_repo(db, resolver)

        repo = db.find_repo(repo_ref)
        repo.sync_failed_at.should_not be_nil
        repo.synced_at.should be_nil
      end
    end
  end

  it "yanks removed releases" do
    transaction do |db|
      shard_id = Factory.create_shard(db)
      db.connection.exec <<-SQL, shard_id
        INSERT INTO releases (shard_id, version, released_at, spec, revision_info, position, latest, yanked_at)
        VALUES ($1, '0.1.0', '2018-12-30 00:00:00 UTC', '{}', '{}', 4, NULL, NULL),
               ($1, '0.1.1', '2018-12-30 00:00:01 UTC', '{}', '{}', 1, NULL, NOW()),
               ($1, '0.1.2', '2018-12-30 00:00:00 UTC', '{}', '{}', 10, NULL, NULL),
               ($1, '0.1.3', '2018-12-30 00:00:02 UTC', '{}', '{}', 3, true, NULL)
        SQL

      service = Service::SyncRepo.new(-1)

      valid_versions = ["0.1.0", "0.1.2"]
      service.yank_releases_with_missing_versions(db, shard_id, valid_versions)

      results = db.connection.query_all <<-SQL, as: {String, Bool?, Bool}
        SELECT
          version, latest, yanked_at IS NULL
        FROM releases
        ORDER BY position
        SQL

      results.should eq [{"0.1.1", nil, false}, {"0.1.3", true, false}, {"0.1.0", nil, true}, {"0.1.2", nil, true}]
    end
  end

  it "#sync_metadata" do
    transaction do |db|
      repo_id = db.connection.query_one <<-SQL, as: Int64
        INSERT INTO repos
          (resolver, url, synced_at, sync_failed_at)
        VALUES
          ('git', 'foo', NOW() - interval '1h', NOW())
        RETURNING id
        SQL

      service = Service::SyncRepo.new(repo_id)

      mock_resolver = MockResolver.new(metadata: {"foo" => JSON::Any.new("bar")})
      resolver = Repo::Resolver.new(mock_resolver, Repo::Ref.new("git", "foo"))
      service.sync_metadata(db, resolver)

      results = db.connection.query_all <<-SQL, as: {JSON::Any, Bool, Time?}
        SELECT
          metadata, synced_at > NOW() - interval '1s', sync_failed_at
        FROM repos
        SQL

      results.should eq [{JSON.parse(%({"foo": "bar"})), true, nil}]
    end
  end
end
