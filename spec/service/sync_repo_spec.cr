require "spec"
require "../../src/service/sync_repo"
require "../support/db"
require "../support/mock_resolver"
require "../support/raven"

describe Service::SyncRepo do
  describe "#sync_repo" do
    it "successfully syncs" do
      transaction do |db|
        repo_ref = Repo::Ref.new("git", "foo")
        shard_id = Factory.create_shard(db, "foo")
        repo_id = Factory.create_repo(db, repo_ref, shard_id: shard_id)
        service = Service::SyncRepo.new(db, repo_ref)

        resolver = Repo::Resolver.new(MockResolver.new, repo_ref)

        db.last_repo_activity.should eq(nil)

        service.sync_repo(resolver)

        repo = db.get_repo(repo_ref)
        repo.sync_failed_at.should be_nil
        repo.synced_at.should_not be_nil

        db.last_repo_activity.should eq({repo_id, "sync_repo:synced"})

        service.sync_repo(resolver)
      end
    end

    it "handles unresolvable repo" do
      transaction do |db|
        repo_ref = Repo::Ref.new("git", "foo")
        repo_id = Factory.create_repo(db, repo_ref)
        service = Service::SyncRepo.new(db, repo_ref)

        resolver = Repo::Resolver.new(MockResolver.unresolvable, repo_ref)
        service.sync_repo(resolver)

        repo = db.get_repo(repo_ref)
        repo.sync_failed_at.should_not be_nil
        repo.synced_at.should be_nil

        db.last_repo_activity.should eq({repo_id, "sync_repo:fetch_spec_failed"})
      end
    end
  end

  describe "#sync_releases" do
    it "skips new invalid release" do
      transaction do |db|
        shard_id = Factory.create_shard(db)
        repo_ref = Repo::Ref.new("git", "foo")
        repo_id = Factory.create_repo(db, repo_ref, shard_id: shard_id)
        mock_resolver = MockResolver.new
        mock_resolver.register "0.1.0", Factory.build_revision_info, spec: ""
        resolver = Repo::Resolver.new(mock_resolver, repo_ref)

        service = Service::SyncRepo.new(db, repo_ref)
        service.sync_releases(resolver, shard_id)

        db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
          {"sync_repo:sync_release:failed", repo_id, shard_id, {
            "message"   => "Expected DOCUMENT_START but was STREAM_END at line 1, column 1",
            "version"   => "0.1.0",
            "exception" => "Shards::ParseError",
          }},
        ]
      end
    end

    it "yanks existing invalid release" do
      transaction do |db|
        shard_id = Factory.create_shard(db, "foo")
        repo_ref = Repo::Ref.new("git", "foo")
        repo_id = Factory.create_repo(db, repo_ref, shard_id: shard_id)
        Factory.create_release(db, shard_id, "0.1.0")
        mock_resolver = MockResolver.new
        mock_resolver.register "0.1.0", Factory.build_revision_info, spec: ""
        mock_resolver.register "0.2.0", Factory.build_revision_info, spec: nil
        resolver = Repo::Resolver.new(mock_resolver, repo_ref)

        service = Service::SyncRepo.new(db, repo_ref)
        service.sync_releases(resolver, shard_id)

        db.all_releases(shard_id).map { |r| {r.version, r.yanked?} }.should eq [{"0.2.0", false}, {"0.1.0", true}]
        db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
          {"sync_repo:sync_release:failed", repo_id, shard_id, {
            "message"   => "Expected DOCUMENT_START but was STREAM_END at line 1, column 1",
            "version"   => "0.1.0",
            "exception" => "Shards::ParseError",
          }},
        ]
      end
    end

    it "yanks HEAD when version found" do
      transaction do |db|
        shard_id = Factory.create_shard(db, "foo")
        repo_ref = Repo::Ref.new("git", "foo")
        repo_id = Factory.create_repo(db, repo_ref, shard_id: shard_id)
        Factory.create_release(db, shard_id, "HEAD")
        mock_resolver = MockResolver.new
        mock_resolver.register "0.1.0", Factory.build_revision_info, spec: nil
        resolver = Repo::Resolver.new(mock_resolver, repo_ref)

        service = Service::SyncRepo.new(db, repo_ref)
        service.sync_releases(resolver, shard_id)

        db.all_releases(shard_id).map { |r| {r.version, r.yanked?} }.should eq [{"HEAD", true}, {"0.1.0", false}]
        db.last_activities.should eq [] of LogActivity
      end
    end

    it "inserts HEAD when all versions yanked" do
      transaction do |db|
        shard_id = Factory.create_shard(db, "foo")
        repo_ref = Repo::Ref.new("git", "foo")
        repo_id = Factory.create_repo(db, repo_ref, shard_id: shard_id)
        Factory.create_release(db, shard_id, "0.1.0")#, position: 0)

        mock_resolver = MockResolver.new
        mock_resolver.register "HEAD", Factory.build_revision_info, spec: nil
        resolver = Repo::Resolver.new(mock_resolver, repo_ref)

        service = Service::SyncRepo.new(db, repo_ref)
        service.sync_releases(resolver, shard_id)

        db.all_releases(shard_id).map { |r| {r.version, r.yanked?} }.should eq [{"HEAD", false}, {"0.1.0", true}]
        db.last_activities.should eq [] of LogActivity
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

      service = Service::SyncRepo.new(db, Repo::Ref.new("git", "blank"))

      valid_versions = ["0.1.0", "0.1.2"]
      service.yank_releases_with_missing_versions(shard_id, valid_versions)

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

      repo_ref = Repo::Ref.new("git", "foo")
      service = Service::SyncRepo.new(db, repo_ref)

      mock_resolver = MockResolver.new(metadata: Repo::Metadata.new(forks_count: 42))
      resolver = Repo::Resolver.new(mock_resolver, repo_ref)
      repo = Repo.new(repo_ref, nil, id: repo_id)
      service.sync_metadata(resolver, repo)

      results = db.connection.query_all <<-SQL, as: {JSON::Any, Bool, Time?}
        SELECT
          metadata, synced_at > NOW() - interval '1s', sync_failed_at
        FROM repos
        SQL

      results.should eq [{JSON.parse(%({"forks_count": 42})), true, nil}]
    end
  end
end
