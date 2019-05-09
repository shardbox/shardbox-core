require "taskmaster"
require "../db"

struct Service::UpdateShardMetrics
  include Taskmaster::Job

  def initialize
  end

  def perform
    ShardsDB.transaction do |db|
      perform(db)
    end
  end

  def perform(db)
    shard_ids = db.connection.query_all <<-SQL, as: Int64
      SELECT
        id
      FROM
        shards
      SQL
    shard_ids.each do |id|
      update_shard_metrics(db, id)
    end
  end

  def update_shard_metrics(db, id)
    db.connection.exec <<-SQL, id
      SELECT shard_metrics_calculate($1)
    SQL
  end
end
