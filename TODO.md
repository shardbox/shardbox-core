# TODO

* Resolve repo redirects: URLs (including Github etc. are not necessarily normalized).
  Example: https://github.com/luckyframework/cli -> https://github.com/luckyframework/lucky_cli

## Name

* Shardarium
* Shardotheque
* Shard Collection

# Open Questions


## Simple, fault-tolerant, global naming schema for shards.

Shards should generally be known by their name. But name clashes need to be resolved.

Example: kemal

* Main repo: github:kemalcr/kemal
* Alternative old repo: github:sdogruyol/kemal
* There are also forks referenced as dependencies (for example github:matomo/kemal)

Suggestion:

* Shards are identified by name (e.g. `kemal`) and qualifier (e.g. `kemalcr`, `matomo`)
* Qualifier can be omitted for "main" shard (usually the first one registered). This is either implemented by a flag or nilable qualifier.
* Slug could look like `kemal` (main shard `kemalcr/kemal`) and `kemal~matomo` (fork `matomo/kemal`)
* Avoids `/` as delimiter for easier use in HTTP routes and to distinguish from github `<org>/<project>` scheme.
* Need to determine if this nomenclature should only be used for forks or also for entirely different shards, just sharing the same name. This is obviously bad by itself, but can't be avoided without a centralized registry. It's probably hard to tell these two cases apart. In case of unrelated name clas, we might consider to always require a qualifier.

## How to express unresolvable dependencies (i.e. local `path` dependencies?)

Some publicly hosted gems have local `path` dependencies. They can't be resolved.

Dependencies should be listed -> needs special entries for dependencies table.

Shards should be marked as having non-resolvable dependencies.
