require "spec"
require "../../src/service/order_releases"
require "../support/db"

describe Service::OrderReleases do
  it "orders releases by version number" do
    transaction do |db|
      shard_id = Factory.create_shard(db)

      versions = {"0.1.0", "0.2.0", "5.333.1", "5.2.1", "0.2", "0.2.0.1", "5.8", "0.0.0.11"}

      versions.each_with_index do |version, index|
        Factory.create_release(db, shard_id, version, Time.utc, position: index)
      end

      service = Service::OrderReleases.new(shard_id)
      service.order_releases(db)

      results = db.connection.query_all <<-SQL, shard_id, as: {String}
        SELECT version
        FROM releases
        WHERE shard_id = $1
        ORDER BY position
        SQL

      results.should eq ["0.0.0.11", "0.1.0", "0.2", "0.2.0", "0.2.0.1", "5.2.1", "5.8", "5.333.1"]

      results = db.connection.query_all <<-SQL, shard_id, as: {String}
        SELECT version
        FROM releases
        WHERE shard_id = $1 AND latest = true
        SQL

      results.should eq ["5.333.1"]
    end
  end
end
