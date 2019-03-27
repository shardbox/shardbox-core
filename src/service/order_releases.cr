require "taskmaster"
require "../db"
require "../release"
require "../util/software_version"

class Service::OrderReleases
  include Taskmaster::Job

  def initialize(@shard_id : Int64)
  end

  def perform
    ShardsDB.transaction do |db|
      order_releases(db)
    end
  end

  struct ReleaseInfo
    include Comparable(ReleaseInfo)

    getter id
    getter version
    getter? yanked

    def initialize(@id : Int64, version : String, @yanked : Bool)
      @version = SoftwareVersion.new(version)
    end

    def <=>(other : self)
      version <=> other.version
    end
  end

  def order_releases(db)
    # sort releases
    sorted_releases = find_releases(db).sort

    # Deferred constraint check lets us switch positions without triggering
    # unique index violations.
    db.connection.exec "SET CONSTRAINTS releases_position_uniq DEFERRED"

    sorted_releases.each_with_index do |release, index|
      db.connection.exec <<-SQL, release.id, index
        UPDATE releases
        SET
          position = $2
        WHERE
          id = $1
        SQL
    end

    # The unique index constraint can be checked now, should all be good.
    db.connection.exec "SET CONSTRAINTS releases_position_uniq IMMEDIATE"

    set_latest_flag(db, sorted_releases)
  end

  def find_releases(db)
    # NOTE: We exclude HEAD versions because they can't be sorted and when there
    # is a HEAD version it means there are no tags anyway, so there is no need
    # to order anyway.
    sql = <<-SQL
      SELECT id, version, yanked_at IS NOT NULL
      FROM releases
      WHERE
        shard_id = $1 AND version != 'HEAD'
      SQL

    releases = [] of ReleaseInfo
    db.connection.query_all sql, @shard_id do |result_set|
      releases << ReleaseInfo.new(*result_set.read(Int64, String, Bool))
    end
    releases
  end

  def set_latest_flag(db, sorted_releases)
    latest = sorted_releases.reverse_each.find do |release|
      !release.yanked? && !release.version.prerelease?
    end

    if latest
      db.connection.exec <<-SQL, latest.id
        UPDATE releases
        SET
          latest = true
        WHERE
          id = $1
        SQL
    else
      db.connection.exec <<-SQL, @shard_id
        UPDATE releases
        SET
          latest = false
        WHERE
          shard_id = $1 AND latest = true
        SQL
    end
  end
end
