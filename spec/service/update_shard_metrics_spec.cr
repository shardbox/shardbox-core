require "spec"
require "../../src/service/update_shard_metrics"
require "../support/db"
require "../support/factory"
require "../support/raven"

describe Service::UpdateShardMetrics do
  it "calcs shard dependencies" do
    transaction do |db|
      db.connection.on_notice do |notice|
        puts notice
      end

      service = Service::UpdateShardMetrics.new(db)
      service.perform
    end
  end
end
