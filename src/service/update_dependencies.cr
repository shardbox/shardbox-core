require "taskmaster"
require "../db"

struct Service::UpdateDependencies
  include Taskmaster::Job

  def initialize
  end

  def perform
    ShardsDB.transaction do |db|
      perform(db)
    end
  end

  def perform(db)
    update_shard_dependencies(db)
  end

  def update_shard_dependencies(db)
    db.connection.exec <<-SQL
      SELECT shard_dependencies_materialize()
    SQL
  end
end
