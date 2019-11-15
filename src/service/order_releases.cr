require "../db"
require "../release"
require "../util/software_version"

class Service::OrderReleases
  def initialize(@db : ShardsDB, @shard_id : Int64)
  end

  def perform
    order_releases
  end

  def order_releases
    # sort releases
    sorted_releases = find_releases.sort

    # Deferred constraint check lets us switch positions without triggering
    # unique index violations.
    @db.connection.exec "SET CONSTRAINTS releases_position_uniq DEFERRED"

    sorted_releases.each_with_index do |release, index|
      @db.connection.exec <<-SQL, release.id, index
        UPDATE
          releases
        SET
          position = $2
        WHERE
          id = $1
        SQL
    end

    # The unique index constraint can be checked now, should all be good.
    @db.connection.exec "SET CONSTRAINTS releases_position_uniq IMMEDIATE"

    set_latest_flag(sorted_releases)
  end

  def find_releases
    # NOTE: We exclude HEAD versions because they can't be sorted and when there
    # is a HEAD version it means there are no tags at all, so there is no need
    # to order anyway.
    sql = <<-SQL
      SELECT
        id, version, yanked_at IS NOT NULL
      FROM
        releases
      WHERE
        shard_id = $1
      SQL

    releases = [] of ReleaseInfo
    @db.connection.query_all sql, @shard_id do |result_set|
      releases << ReleaseInfo.new(*result_set.read(Int64, String, Bool))
    end
    releases
  end

  def set_latest_flag(sorted_releases)
    latest = sorted_releases.reverse_each.find do |release|
      !release.yanked? && !release.version.try(&.prerelease?)
    end

    if latest
      @db.connection.exec <<-SQL, latest.id
        UPDATE releases
        SET
          latest = true
        WHERE
          id = $1
        SQL
    else
      @db.connection.exec <<-SQL, @shard_id
        UPDATE releases
        SET
          latest = NULL
        WHERE
          shard_id = $1 AND latest = true
        SQL
    end
  end

  struct ReleaseInfo
    include Comparable(ReleaseInfo)

    getter id
    getter version
    getter? yanked

    def initialize(@id : Int64, version : String, @yanked : Bool)
      @version = SoftwareVersion.parse?(version)
    end

    def <=>(other : self)
      if version = self.version
        if other_version = other.version
          version <=> other_version
        else
          -1
        end
      else
        other.version ? 1 : 0
      end
    end
  end
end
