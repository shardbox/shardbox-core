DATABASE_NAME ?= $(shell echo $(DATABASE_URL) | grep -o -P '[^/]+$$')
TEST_DATABASE_NAME ?= $(shell echo $(TEST_DATABASE_URL) | grep -o -P '[^/]+$$')
PG_USER ?= postgres
BIN ?= bin
DBMATE := dbmate
SHARDS := shards

.PHONY: build
build: $(BIN)/worker

.PHONY: DATABASE_URL
DATABASE_URL:
	@test "${$@}" || (echo "$@ is undefined" && false)

.PHONY: TEST_DATABASE_URL
TEST_DATABASE_URL:
	@test "${$@}" || (echo "$@ is undefined" && false)

.PHONY: test_db
test_db: TEST_DATABASE_URL
	@psql $(TEST_DATABASE_NAME) -c "SELECT 1" > /dev/null 2>&1 || \
	(createdb -U $(PG_USER) $(TEST_DATABASE_NAME) && psql -U $(PG_USER) $(TEST_DATABASE_NAME) < db/schema.sql)

.PHONY: db
db: DATABASE_URL
	@psql $(DATABASE_NAME) -c "SELECT 1" > /dev/null 2>&1 || \
	createdb -U $(PG_USER) $(DATABASE_NAME)
	psql -U $(PG_USER) $(DATABASE_NAME) -c "CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;"
	dbmate up

.PHONY: db/dump
db/dump: DATABASE_URL
	pg_dump -U $(PG_USER) -d $(DATABASE_NAME) -a -Tschema_migrations --disable-triggers > db/dump/$(shell date +'%Y-%m-%d-%H%M').sql

.PHONY: db/dump_schema
db/dump_schema: DATABASE_URL
	pg_dump -U $(PG_USER) -s $(DATABASE_NAME) > db/schema.sql

$(BIN):
	mkdir $(BIN)

.PHONY: $(BIN)/worker
$(BIN)/worker: src/worker.cr $(BIN) shard.lock
	crystal build src/worker.cr -o $(@)

shard.lock: shard.yml
	$(SHARDS) update

.PHONY: test
test: test_db
	crystal spec

.PHONY: test_db/drop_sync
test_db/drop_sync: test_db/drop
	createdb -U $(PG_USER) $(TEST_DATABASE_NAME) 2> /dev/null
	pg_dump -U $(PG_USER) -s $(DATABASE_NAME) | psql -U $(PG_USER) $(TEST_DATABASE_NAME) -q

.PHONY: test_db/drop
test_db/drop:
	dropdb -U $(PG_USER) $(TEST_DATABASE_NAME) || true

.PHONY: test/migration
test/migration: test_db/rollback test_db/migrate
	git diff --exit-code db/schema.sql

.PHONY: test_db/migrate
test_db/migrate:
	$(DBMATE) -e TEST_DATABASE_URL migrate

.PHONY: test_db/rollback
test_db/rollback:
	$(DBMATE) -e TEST_DATABASE_URL rollback

.PHONY: db/migrate
db/migrate:
	$(DBMATE) -e DATABASE_URL migrate

.PHONY: db/rollback
db/rollback:
	$(DBMATE) -e DATABASE_URL rollback
