require "../db"

struct Service::UpdateShard
  def initialize(@shard_id : Int64, @entry : Catalog::Entry?)
  end

  def perform
    ShardsDB.transaction do |db|
      perform(db)
    end
  end

  def perform(db)
    update_shard(db, @shard_id, @entry)
  end

  def update_shard(db, shard_id, entry)
    return unless entry

    shard = db.get_shard(shard_id)

    if shard.archived? && !entry.archived?
      # unarchive
      shard.archived_at = nil
      db.log_activity("update_shard:unarchived", nil, shard_id)
    elsif !shard.archived? && entry.archived?
      # archive
      shard.archived_at = Time.utc
      db.log_activity("update_shard:archived", nil, shard_id)
    end

    if entry.description != shard.description
      db.log_activity("update_shard:description_changed", nil, shard_id, metadata: {"old_value": shard.description})
      shard.description = entry.description
    end

    db.connection.exec <<-SQL, shard_id, shard.description, shard.archived_at
      UPDATE
        shards
      SET
        description = $2,
        archived_at = $3
      WHERE
        id = $1
      SQL
  end
end
