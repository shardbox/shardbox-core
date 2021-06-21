-include Makefile.local # for optional local options

BUILD_TARGET ::= bin/worker

# The dbmate command to use
DBMATE ?= dbmate
# The shards command to use
SHARDS ?= shards
# The crystal command to use
CRYSTAL ?= crystal

SRC_SOURCES ::= $(shell find src -name '*.cr' 2>/dev/null)
LIB_SOURCES ::= $(shell find lib -name '*.cr' 2>/dev/null)
SPEC_SOURCES ::= $(shell find spec -name '*.cr' 2>/dev/null)

DATABASE_NAME ::= $(shell echo $(DATABASE_URL) | grep -o -P '[^/]+$$')
TEST_DATABASE_NAME ::= $(shell echo $(TEST_DATABASE_URL) | grep -o -P '[^/]+$$')

.PHONY: build
build: ## Build the application binary
build: $(BUILD_TARGET)

$(BUILD_TARGET): $(SRC_SOURCES) $(LIB_SOURCES) lib
	mkdir -p $(shell dirname $(@))
	$(CRYSTAL) build src/worker.cr -o $(@)

.PHONY: test
test: ## Run the test suite
test: lib test_db
	$(CRYSTAL) spec

.PHONY: format
format: ## Apply source code formatting
format: $(SRC_SOURCES) $(SPEC_SOURCES)
	$(CRYSTAL) tool format src spec

docs: ## Generate API docs
docs: $(SRC_SOURCES) lib
	$(CRYSTAL) docs -o docs

lib: shard.lock
	$(SHARDS) install
	# Touch is necessary because `shards install` always touches shard.lock
	touch lib

shard.lock: shard.yml
	$(SHARDS) update

.PHONY: DATABASE_URL
DATABASE_URL:
	@test "${$@}" || (echo "$@ is undefined" && false)

.PHONY: TEST_DATABASE_URL
TEST_DATABASE_URL:
	@test "${$@}" || (echo "$@ is undefined" && false)

.PHONY: test_db
test_db: TEST_DATABASE_URL
	@psql $(TEST_DATABASE_NAME) -c "SELECT 1" > /dev/null 2>&1 || \
	(createdb $(TEST_DATABASE_NAME) && psql $(TEST_DATABASE_NAME) < db/extension.sql && psql $(TEST_DATABASE_URL) < db/schema.sql)

.PHONY: db
db: DATABASE_URL
	@psql $(DATABASE_NAME) -c "SELECT 1" > /dev/null 2>&1 || \
	createdb $(DATABASE_NAME)
	psql $(DATABASE_NAME) -c "CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;"
	$(DBMATE) up

.PHONY: db/dump
db/dump: DATABASE_URL
	pg_dump -d $(DATABASE_NAME) -a -Tschema_migrations --disable-triggers > db/dump/$(shell date +'%Y-%m-%d-%H%M').sql

.PHONY: db/dump_schema
db/dump_schema: DATABASE_URL
	pg_dump -s $(DATABASE_NAME) > db/schema.sql

.PHONY: test_db/drop_sync
test_db/drop_sync: test_db/drop
	createdb $(TEST_DATABASE_NAME) 2> /dev/null
	pg_dump -s $(DATABASE_NAME) | psql $(TEST_DATABASE_NAME) -q

.PHONY: test_db/drop
test_db/drop:
	dropdb $(TEST_DATABASE_NAME) || true

.PHONY: test/migration
test/migration:
	git add db/schema.sql
	make test_db/rollback test_db/migrate
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

vendor/bin/dbmate:
	mkdir -p vendor/bin
	wget -qO "$@" https://github.com/amacneil/dbmate/releases/download/v1.7.0/dbmate-linux-amd64
	chmod +x "$@"

.PHONY: clean
clean: ## Remove application binary
clean:
	@rm -f $(BUILD_TARGET)

.PHONY: help
help: ## Show this help
	@echo
	@printf '\033[34mtargets:\033[0m\n'
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) |\
		sort |\
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo
	@printf '\033[34moptional variables:\033[0m\n'
	@grep -hE '^[a-zA-Z_-]+ \?=.*?## .*$$' $(MAKEFILE_LIST) |\
		sort |\
		awk 'BEGIN {FS = " \\?=.*?## "}; {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}'
	@echo
	@printf '\033[34mrecipes:\033[0m\n'
	@grep -hE '^##.*$$' $(MAKEFILE_LIST) |\
		awk 'BEGIN {FS = "## "}; /^## [a-zA-Z_-]/ {printf "  \033[36m%s\033[0m\n", $$2}; /^##  / {printf "  %s\n", $$2}'
