require "./factory"

ShardsDB.database_url = ENV["TEST_DATABASE_URL"]

def transaction
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
