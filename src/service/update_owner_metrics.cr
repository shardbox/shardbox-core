require "../db"

struct Service::UpdateOwnerMetrics
  def initialize
  end

  def perform
    ShardsDB.transaction do |db|
      perform(db)
    end
  end

  def perform(db)
    owner_ids = db.connection.query_all <<-SQL, as: Int64
      SELECT
        id
      FROM
        owners
      SQL
    owner_ids.each do |id|
      update_owner_metrics(db, id)
    end
  end

  def update_owner_metrics(db, id)
    db.connection.exec <<-SQL, id
      SELECT owner_metrics_calculate($1)
    SQL
  end
end
