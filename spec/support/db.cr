require "./factory"

ShardsDB.database_url = ENV["SHARDSDB_TEST_DATABASE"]

def transaction
  ShardsDB.transaction do |db, transaction|
    yield db, transaction

    transaction.rollback
  end
end
