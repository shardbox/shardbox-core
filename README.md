# shardbox-core

Shards database, collecting shard repositories, releases and dependencies.

## Installation

### Prerequisites

* Crystal 0.30.1
* PostgresSQL database (for data storage).
  Should probably work with all versions => 10. Tested with PostgreSQL 11.5

PostgreSQL databases needs to be created manually.
Connection configuration is read from environment variables:

* development database: `DATABASE_URL`
* testing database: `TEST_DATABASE_URL` (only for running tests)
* sentry: `SENTRY_DSN` (optional, for sending error reports to sentry)

Install database schema by running `make db test_db`.

### Shard Dependencies

Run `shards install` to install dependencies.

## Usage

Run `shards build worker` to build the worker executable.

* `bin/worker import_catalog`: Reads repositories mentioned in `catalog/*.yml` files and
  synchronizes them with the database.
* `bin/worker sync_repos [hours [ratio]]`: Synchronizes data from git repositories to database for all
  repositories not synced in the last `hours` hours (default: `24`) or never synced at all. `ratio`
  specifies the amount of outdated repositories being run in this job (default: `2.0 / hours`).
  This enables an even distribution of batch sizes. Recommended to be run every hour.
* `bin/worker updated_metrics`: Updates shard metrics in the database. Should be run once per day.

A web application for browsing the database is available at https://github.com/shardbox/shardbox-web

## Development

Run `make test` to execute the spec suite.

## Contributing

1. Fork it (<https://github.com/shardbox/shardbox-web/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Johannes Müller](https://github.com/straight-shoota) - creator and maintainer
