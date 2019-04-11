require "../db"

struct Service::UpdateDependencies
  def perform(db)
    update_shard_dependencies(db)
    update_dependents_stats(db)
  end

  def update_shard_dependencies(db)
    db.connection.exec <<-SQL
      shard_dependencies_materialize()
    SQL
  end

  def update_dependents_stats(db)
    db.connection.exec <<-SQL
      SELECT shards_refresh_dependents()
    SQL
  end
end
