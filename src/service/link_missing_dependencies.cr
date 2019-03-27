require "../db"
require "./link_dependencies"
require "taskmaster"

# This service tries to connect dependency references to already registered shards.
class Service::LinkMissingDependencies
  include Taskmaster::Job

  def perform
    ShardsDB.transaction do |db|
      link_missing_dependencies(db)
    end
  end

  def link_missing_dependencies(db)
    releases = db.connection.query_all <<-SQL, as: Int64
      SELECT DISTINCT
        release_id
      FROM
        dependencies
      WHERE
        shard_id IS NULL AND resolvable
      SQL

    releases.each do |release_id|
      Service::LinkDependencies.new(release_id).perform_later
    end
  end
end
