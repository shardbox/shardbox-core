require "taskmaster"
require "../db"

struct Service::UpdateShard
  include Taskmaster::Job

  def initialize(@shard_id : Int64, @description : String?)
  end

  def perform
    ShardsDB.transaction do |db|
      perform(db)
    end
  end

  def perform(db)
    update_shard(db, @shard_id, @description)
  end

  def update_shard(db, shard_id, description)
    # Update metadata
    db.connection.exec <<-SQL, description, shard_id
      UPDATE
        shards
      SET
        description = $1
      WHERE
        id = $2
      SQL
  end
end
