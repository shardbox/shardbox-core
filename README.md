# shardsdb

Shards database, collecting shard repositories, releases and dependencies.

## Installation

### Prerequisites

* Crystal 0.27.0
* PostgresSQL database (for data storage).
  Should probably work with all versions beginning with 9.5 or so. Tested with PostgreSQL 11.
* Redis server (for job queue).
  Tested with 3.0.6.

PostgreSQL databases needs to be created manually.
Connection configuration is read from environment variables:

* development database: `SHARDSDB_DATABASE`
* testing database: `SHARDSDB_TEST_DATABASE`

Install database schema by running `make db test_db`.

Redis is expected to run on localhost with default port (`6379`).

### Shard Dependencies

Run `shards install` to install dependencies.

## Usage

Run `shards build worker` to build the worker executable.

* `bin/worker import_catalog`: Reads repositories mentioned in `catalog/*.yml` files and
  enqueues jobs for importing these as shards into the database.
* `bin/worker`: Executes the job queue. You can run multiple instances in parallel to
  improve job bandwidth.
* `bin/worker sync_repos [age]`: Synchronizes data from git repositories to database for all
  repositories not synched in the last `age` hours (default: `24`) or never synced at all.
* `bin/worker link_missing_dependencies`: Connects dependencies specified in a shards
  `shard.yml` with shards available in the database. If not available, the shard is queued
  for import. This command is for maintenance only and usually not required.

There is currently no user interface for retrieving or displaying data.
Connect to the database and look around.

## Development

Run `make test` to execute the spec suite.

## Contributing

1. Fork it (<https://github.com/your-github-user/shards-toolbox/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Johannes Müller](https://github.com/straight-shoota) - creator and maintainer
