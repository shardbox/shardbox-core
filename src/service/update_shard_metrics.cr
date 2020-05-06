require "../db"

struct Service::UpdateShardMetrics
  def initialize(@db : ShardsDB)
  end

  def perform
    shard_ids = @db.connection.query_all <<-SQL, as: Int64
      SELECT
        id
      FROM
        shards
      SQL
    shard_ids.each do |id|
      update_shard_metrics(id)
    end
  end

  def update_shard_metrics(id)
    @db.connection.exec <<-SQL, id
      SELECT shard_metrics_calculate($1)
    SQL
  end
end
