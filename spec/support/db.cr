require "./factory"
require "../../src/db"

ShardsDB.database_url = ENV["TEST_DATABASE_URL"]

def transaction(&)
  ShardsDB.transaction do |db, transaction|
    db.connection.on_notice do |notice|
      puts
      print "NOTICE from PG: "
      puts notice
    end

    yield db, transaction

    transaction.rollback
  end
end

class ShardsDB
  def last_repo_activity
    connection.query_one? <<-SQL, as: {Int64, String}
      SELECT
        repo_id, event, created_at
      FROM
        activity_log
      WHERE
        repo_id IS NOT NULL
      ORDER BY created_at DESC
      LIMIT 1
      SQL
  end
end

module ShardsDBHelper
  def self.persisted_shards(db)
    db.connection.query_all <<-SQL, as: {String, String, String?}
          SELECT
            name::text, qualifier::text, description::text
          FROM shards
          ORDER BY name, qualifier
          SQL
  end
end
