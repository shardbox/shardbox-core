# ShardsDB Data Model

All relevant information is stored in a PostgreSQL database.

The database is the single source of truth and contains a pronounced data model
which ensures consistency of values and references inside the database. Thus the
database is independent of validations provided by ORM. Constraints and triggers
are in place to make sure the data is inherently consistent, regardless of how it
is accessed.

## Models

### Shards

```
+-------------+--------------------------+------------------------------------------------------+
| Column      | Type                     | Modifiers                                            |
|-------------+--------------------------+------------------------------------------------------|
| id          | integer                  |  not null default nextval('shards_id_seq'::regclass) |
| name        | citext                   |  not null                                            |
| qualifier   | citext                   |  not null default ''::citext                         |
| description | text                     |                                                      |
| created_at  | timestamp with time zone |  not null default now()                              |
| updated_at  | timestamp with time zone |  not null default now()                              |
+-------------+--------------------------+------------------------------------------------------+
Indexes:
    "shards_pkey" PRIMARY KEY, btree (id)
    "shards_name_unique" UNIQUE CONSTRAINT, btree (name, qualifier)
Check constraints:
    "shards_name_check" CHECK (name ~ '^[A-Za-z0-9_\-.]{1,100}$'::text)
    "shards_qualifier_check" CHECK (qualifier ~ '^[A-Za-z0-9_\-.]{0,100}$'::citext)
Referenced by:
    TABLE "dependencies" CONSTRAINT "depdendencies_shard_id_fkey" FOREIGN KEY (shard_id) REFERENCES shards(id)
    TABLE "releases" CONSTRAINT "specs_shard_id_fkey" FOREIGN KEY (shard_id) REFERENCES shards(id)
    TABLE "repos" CONSTRAINT "repos_shard_id_fkey" FOREIGN KEY (shard_id) REFERENCES shards(id) ON DELETE CASCADE
Triggers:
    set_timestamp BEFORE UPDATE ON shards FOR EACH ROW EXECUTE PROCEDURE trigger_set_timestamp()
```

### Simple, fault-tolerant, global naming schema for shards

Shards should generally be known by their name. Because of shard's decentralized design, name clashes can't be ruled out.

Name clashes mostly come from forks and mirrors of a shard's repository. But there might also be unrelated repositories with homonymous shards.
This is obviously bad by itself, but can't be avoided without a centralized registry.

Example: kemal

* Main repo: `github:kemalcr/kemal`
* Old repo: `github:sdogruyol/kemal`
* There are also development forks like `github:matomo/kemal`

They all reference in essence the same shard. Forks could be considered as an individual instance but unless they have separate releases, they are not really.

This problem is approached as follows:

* Shards are generally identified by their name as specified in `shard.yml` (e.g. `kemal`) and an additional qualifier (e.g. `kemalcr` or `matomo`)
* Qualifiers can be omitted when there is no ambiguity (probably just first come-first serve). In the database this is expressed as an empty value for `qualifier` (due to enforcing uniqueness constraint). The data mapping should interpret an empty string as `nil`.
* Slug could look like `kemal` (main shard, `kemalcr/kemal`) and `kemal~matomo` (fork, `matomo/kemal`)
* Avoids `/` as delimiter for easier use in HTTP routes and to distinguish from github `<org>/<project>` scheme.

This is still a trial, and not confirmed to work well with all real-world scenarios.
Especially, it needs to be determined if this nomenclature works for both forks and mirrors as well as entirely different shards, just sharing the same name. It's probably not always easy to tell these two cases apart.

### Repos

```
+------------+--------------------------+-----------------------------------------------------+
| Column     | Type                     | Modifiers                                           |
|------------+--------------------------+-----------------------------------------------------|
| id         | integer                  |  not null default nextval('repos_id_seq'::regclass) |
| shard_id   | integer                  |  not null                                           |
| resolver   | repo_resolver            |  not null                                           |
| url        | citext                   |  not null                                           |
| role       | repo_role                |  not null default 'canonical'::repo_role            |
| synced_at  | timestamp with time zone |                                                     |
| created_at | timestamp with time zone |  not null default now()                             |
| updated_at | timestamp with time zone |  not null default now()                             |
+------------+--------------------------+-----------------------------------------------------+
Indexes:
    "repos_pkey" PRIMARY KEY, btree (id)
    "repos_shard_id_role_idx" UNIQUE, btree (shard_id, role) WHERE role = 'canonical'::repo_role
    "repos_url_uniq" UNIQUE CONSTRAINT, btree (url, resolver)
Check constraints:
    "repos_resolvers_service_url" CHECK (NOT (resolver = ANY (ARRAY['github'::repo_resolver, 'gitlab'::repo_resolver, 'bitbucket'::repo_resolver])) OR url ~ '^[A-Za-z0-9_Foreign-key constraints:
    "repos_shard_id_fkey" FOREIGN KEY (shard_id) REFERENCES shards(id) ON DELETE CASCADE
Triggers:
    set_timestamp BEFORE UPDATE ON repos FOR EACH ROW EXECUTE PROCEDURE trigger_set_timestamp()
```

NOTES:

* `role` specifies the role of this repo for the shard (defaults to `canonical`). Other values are `mirror` and `fork`. Thus, multiple repositories can be linked to the same shard. This is important for example to preserve continuity when a repository is transferred to a different location (for example `github:sdogruyol/kemal` to `github:kemalcr/kemal`).

### Releases

```
+---------------+--------------------------+--------------------------------------------------------+
| Column        | Type                     | Modifiers                                              |
|---------------+--------------------------+--------------------------------------------------------|
| id            | integer                  |  not null default nextval('releases_id_seq'::regclass) |
| shard_id      | integer                  |  not null                                              |
| version       | character varying        |  not null                                              |
| revision_info | jsonb                    |  not null                                              |
| spec          | jsonb                    |  not null                                              |
| position      | integer                  |                                                        |
| latest        | boolean                  |                                                        |
| released_at   | timestamp with time zone |  not null                                              |
| yanked_at     | timestamp with time zone |                                                        |
| created_at    | timestamp with time zone |  not null default now()                                |
| updated_at    | timestamp with time zone |  not null default now()                                |
+---------------+--------------------------+--------------------------------------------------------+
Indexes:
    "specs_pkey" PRIMARY KEY, btree (id)
    "releases_position_uniq" UNIQUE CONSTRAINT, btree (shard_id, "position") DEFERRABLE INITIALLY DEFERRED
    "releases_shard_id_latest_idx" UNIQUE, btree (shard_id, latest) WHERE latest = true
    "releases_version_uniq" UNIQUE CONSTRAINT, btree (shard_id, version)
Check constraints:
    "releases_latest_check" CHECK (latest <> false)
    "releases_version_check" CHECK (version::text ~ '^[0-9]+(\.[0-9a-zA-Z]+)*(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'::text OR version::text = 'HEAD'::text)
Foreign-key constraints:
    "specs_shard_id_fkey" FOREIGN KEY (shard_id) REFERENCES shards(id)
Referenced by:
    TABLE "dependencies" CONSTRAINT "dependencies_release_id_fkey" FOREIGN KEY (release_id) REFERENCES releases(id) ON DELETE CASCADE
Triggers:
    releases_only_one_latest_release BEFORE INSERT OR UPDATE OF latest ON releases FOR EACH ROW WHEN (new.latest = true) EXECUTE PROCEDURE ensure_only_one_latest_release_
    set_timestamp BEFORE UPDATE ON releases FOR EACH ROW EXECUTE PROCEDURE trigger_set_timestamp()
```

NOTES:

* Releases are bound to a shard (`shard_id`), not an individual repo because repo locations may change. We consider each shard to have a unique release history.
* `position` is a utility column used to sort versions because postgresql doesn't provide proper comparison operator for version strings. There is a `semver` extension, but it requires versions to follow SEMVER, which is not enforced by shards. So we need to enforce this externally using `Service::OrderReleases`. A further enhancement would be to use a trigger and notify channel to automatically request a reorder job, when a version is added or removed.
* If a release has been deleted from the repo (i.e. the tag was removed) it is marked as `yanked`. This procedure needs refinement. Yanked releases should still be addressable.
* When a tag is changed to point to a different commit, it is simply updated. This also needs refinement.

### Dependencies

```
+------------+--------------------------+-------------------------+
| Column     | Type                     | Modifiers               |
|------------+--------------------------+-------------------------|
| release_id | integer                  |  not null               |
| shard_id   | integer                  |                         |
| name       | citext                   |  not null               |
| spec       | jsonb                    |  not null               |
| scope      | dependency_scope         |  not null               |
| resolvable | boolean                  |  not null               |
| created_at | timestamp with time zone |  not null default now() |
| updated_at | timestamp with time zone |  not null default now() |
+------------+--------------------------+-------------------------+
Indexes:
    "dependencies_uniq" UNIQUE CONSTRAINT, btree (release_id, name)
Foreign-key constraints:
    "depdendencies_shard_id_fkey" FOREIGN KEY (shard_id) REFERENCES shards(id)
    "dependencies_release_id_fkey" FOREIGN KEY (release_id) REFERENCES releases(id) ON DELETE CASCADE
Triggers:
    set_timestamp BEFORE UPDATE ON dependencies FOR EACH ROW EXECUTE PROCEDURE trigger_set_timestamp()
```

NOTES:

* `shard_id` points to the shard referenced as dependency. If `NULL`, it could not (yet) be resolved. The dependent shard is available through joining `releases` on `release_id`.
* When a dependency's repository can't be resolved (for example it's a `path` dependency or the URL does not resolve, there is an error, ...) it is marked as `resolvable = false` and won't be revisited in the future. This needs refinement, because the repository might become available at some point.
* Scope is either `runtime` or `dependency`.
