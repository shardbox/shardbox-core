# shardbox-core

Shards database, collecting shard repositories, releases and dependencies.

## Installation

### Prerequisites

* Crystal (0.30.1 or later)
* PostgreSQL database (version 12)
* [dbmate](https://github.com/amacneil/dbmate) for database migrations

#### Database
PostgreSQL databases needs to be created manually.

Connection configuration is read from environment variables.

* development database: `DATABASE_URL`
* testing database: `TEST_DATABASE_URL` (only for running tests)

Install database schema:

* `make db` - development database
* `make test_db` - test database

### Shard Dependencies

Run `shards install` to install dependencies.

## Usage

Run `make bin/worker` to build the worker executable.

* `bin/worker import_catalog https://github.com/shardbox/catalog`:
  Reads catalog description from the catalog repository and imports shards to the database.
* `bin/worker sync_repos`: Synchronizes data from git repositories to database for all
  repositories not synced in the last 24 hours or never synced at all.
  Recommended to be run every hour.
* `bin/worker updated_metrics`: Updates shard metrics in the database. Should be run once per day.
* `bin/worker loop` starts a worker loop which schedules regular `sync_repos` and `update_metrics`
  jobs. It also listens to notifications sent through PostgreSQL notify channels in order
  to trigger catalog import.

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

* [Johannes Müller](https://github.com/straight-shoota) - creator and maintainer
