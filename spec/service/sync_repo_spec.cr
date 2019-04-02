require "spec"
require "../../src/service/sync_repo"
require "../support/db"

describe Service::SyncRepo do
  pending "it syncs repo" do
    # TODO: Write specs
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

      service = Service::SyncRepo.new(shard_id)

      valid_versions = ["0.1.0", "0.1.2"]
      service.yank_releases_with_missing_versions(db, valid_versions)

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
      shard_id = Factory.create_shard(db)
      db.connection.exec <<-SQL, shard_id
        INSERT INTO repos (shard_id, resolver, url, synced_at)
        VALUES ($1, 'git', 'foo', NOW() - interval '1h')
        SQL

      service = Service::SyncRepo.new(shard_id)

      mock_resolver = MockResolver.new(metadata: {"foo" => JSON::Any.new("bar")})
      resolver = Repo::Resolver.new(mock_resolver, Repo::Ref.new("git", "foo"))
      service.sync_metadata(db, resolver)

      results = db.connection.query_all <<-SQL, as: {JSON::Any, Bool}
        SELECT metadata, synced_at > NOW() - interval '1s'
        FROM repos
        SQL

      results.should eq [{JSON.parse(%({"foo": "bar"})), true}]
    end
  end
end
