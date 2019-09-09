require "./factory"

ShardsDB.database_url = ENV["TEST_DATABASE_URL"]

def transaction
  ShardsDB.transaction do |db, transaction|
    yield db, transaction

    transaction.rollback
  end
end
