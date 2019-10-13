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
    db.connection.exec <<-SQL, shard_id, entry.try(&.description)
      UPDATE
        shards
      SET
        description = $2
      WHERE
        id = $1
      SQL
  end
end
