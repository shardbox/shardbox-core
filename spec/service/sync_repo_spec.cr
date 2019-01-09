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
end
