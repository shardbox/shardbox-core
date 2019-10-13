require "taskmaster"
require "../db"

struct Service::UpdateShard
  include Taskmaster::Job

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

    # Update metadata
    archived_at = nil
    if entry.try(&.archived?)
      archived_at = Time.utc
    end

    db.connection.exec <<-SQL, shard_id, entry.try(&.description), archived_at
      UPDATE
        shards
      SET
        description = $2,
        -- don't override archived_at if already set
        --    old: TS1   TS1   NIL   NIL
        --    new: TS2   NIL   TS2   NIL
        -- result: TS1   NIL   TS2   NIL
        archived_at = CASE
          WHEN archived_at IS NULL OR $3::timestamptz IS NULL THEN $3
          ELSE archived_at
          END
      WHERE
        id = $1
      SQL
  end
end
