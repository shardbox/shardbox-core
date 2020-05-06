require "../db"

struct Service::UpdateOwnerMetrics
  def initialize(@db : ShardsDB)
  end

  def perform
    owner_ids = @db.connection.query_all <<-SQL, as: Int64
      SELECT
        id
      FROM
        owners
      SQL
    owner_ids.each do |id|
      update_owner_metrics(id)
    end
  end

  def update_owner_metrics(id)
    @db.connection.exec <<-SQL, id
      SELECT owner_metrics_calculate($1)
    SQL
  end
end
