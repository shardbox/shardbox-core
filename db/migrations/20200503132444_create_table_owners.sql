-- migrate:up
CREATE TABLE public.owners (
    id bigint NOT NULL PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY,
    resolver public.repo_resolver NOT NULL,
    slug public.citext NOT NULL,
    name text,
    description text,
    extra jsonb DEFAULT '{}'::jsonb NOT NULL,
    shards_count integer,
    dependents_count integer,
    transitive_dependents_count integer,
    dev_dependents_count integer,
    transitive_dependencies_count integer,
    dev_dependencies_count integer,
    dependencies_count integer,
    popularity real,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);

CREATE TRIGGER set_timestamp BEFORE UPDATE ON public.owners FOR EACH ROW EXECUTE PROCEDURE public.trigger_set_timestamp();

CREATE UNIQUE INDEX owners_resolver_slug_idx ON public.owners USING btree (resolver, slug);
ALTER TABLE owners
  ADD CONSTRAINT owners_resolver_slug_uniq UNIQUE USING INDEX owners_resolver_slug_idx;

ALTER TABLE repos
  ADD COLUMN owner_id bigint REFERENCES owners(id);

CREATE TABLE public.owner_metrics (
  id bigint NOT NULL PRIMARY KEY GENERATED BY DEFAULT AS IDENTITY,
  owner_id bigint NOT NULL,
  shards_count integer NOT NULL,
  dependents_count integer NOT NULL,
  transitive_dependents_count integer NOT NULL,
  dev_dependents_count integer NOT NULL,
  transitive_dependencies_count integer NOT NULL,
  dev_dependencies_count integer NOT NULL,
  dependencies_count integer NOT NULL,
  popularity real NOT NULL,
  created_at timestamp with time zone DEFAULT now() NOT NULL
);

ALTER TABLE ONLY public.owner_metrics
    ADD CONSTRAINT owner_metrics_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.owners(id) ON DELETE CASCADE DEFERRABLE;

CREATE OR REPLACE FUNCTION public.owner_metrics_calculate(curr_owner_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  aggregated_popularity real;
  local_dev_dependencies_count integer;
BEGIN
  CREATE TEMPORARY TABLE owned_shards
  AS
    SELECT
      shard_id AS id
    FROM repos
    WHERE owner_id = curr_owner_id
      AND repos.role = 'canonical'
  ;

  CREATE TEMPORARY TABLE dependents
  AS
    SELECT
      d.shard_id, depends_on, scope
    FROM
      shard_dependencies d
    JOIN owned_shards
      ON depends_on = owned_shards.id
  ;
  CREATE TEMPORARY TABLE tmp_dependencies
  AS
    SELECT
      d.shard_id, depends_on, scope
    FROM
      shard_dependencies d
    JOIN owned_shards
      ON shard_id = owned_shards.id
  ;

  SELECT
    SUM(popularity) INTO aggregated_popularity
  FROM
    shard_metrics_current
  JOIN owned_shards
    ON owned_shards.id = shard_metrics_current.shard_id
  ;

  SELECT
    COUNT(DISTINCT depends_on) INTO local_dev_dependencies_count
  FROM
    tmp_dependencies
  WHERE
    scope <> 'runtime'
  ;

  UPDATE owners
  SET
    shards_count = (
      SELECT
        COUNT(*)
      FROM
        owned_shards
    ),
    dependents_count = (
      SELECT
        COUNT(DISTINCT shard_id)
      FROM
        dependents
      WHERE
        scope = 'runtime'
    ),
    dev_dependents_count = (
      SELECT
        COUNT(DISTINCT shard_id)
      FROM
        dependents
      WHERE
        scope <> 'runtime'
    ),
    transitive_dependents_count = tdc.transitive_dependents_count,
    dependencies_count = (
      SELECT
        COUNT(DISTINCT depends_on)
      FROM
        tmp_dependencies
      WHERE
        scope = 'runtime'
    ),
    dev_dependencies_count = local_dev_dependencies_count,
    transitive_dependencies_count = (
      WITH RECURSIVE transitive_dependencies AS (
        SELECT
          shard_id, depends_on
        FROM
          tmp_dependencies
        WHERE
          scope = 'runtime'
        UNION
        SELECT
          d.shard_id, d.depends_on
        FROM
          shard_dependencies d
        INNER JOIN
          transitive_dependencies ON transitive_dependencies.depends_on = d.shard_id AND d.scope = 'runtime'
      )
      SELECT
        COUNT(*)
      FROM
      (
        SELECT DISTINCT
          depends_on
        FROM
          transitive_dependencies
      ) AS d
    ),
    popularity = POWER(
        POWER(COALESCE(tdc.transitive_dependents_count, 0) + 1, 1.2) *
        POWER(COALESCE(local_dev_dependencies_count, 0) + 1, 0.6) *
        POWER(COALESCE(aggregated_popularity, 0) + 1, 1.2),
        1.0/3.0
      )
    FROM
      (
        WITH RECURSIVE transitive_dependents AS (
          SELECT
            shard_id, depends_on
          FROM
            dependents
          WHERE
            scope = 'runtime'
          UNION
          SELECT
            d.shard_id, d.depends_on
          FROM
            shard_dependencies d
          INNER JOIN
            transitive_dependents ON transitive_dependents.shard_id = d.depends_on AND d.scope = 'runtime'
        )
        SELECT
          COUNT(*) AS transitive_dependents_count
        FROM
        (
          SELECT DISTINCT
            shard_id
          FROM
            transitive_dependents
        ) AS d
      ) AS tdc
    WHERE
      id = curr_owner_id
  ;

  INSERT INTO owner_metrics
    (
      owner_id,
      shards_count,
      dependents_count, dev_dependents_count, transitive_dependents_count,
      dependencies_count, dev_dependencies_count, transitive_dependencies_count,
      popularity
    )
  SELECT
    id,
    shards_count,
    dependents_count, dev_dependents_count, transitive_dependents_count,
    dependencies_count, dev_dependencies_count, transitive_dependencies_count,
    popularity
  FROM
    owners
  WHERE id = curr_owner_id;

  DROP TABLE dependents;
  DROP TABLE tmp_dependencies;
  DROP TABLE owned_shards;
END;
$$;

-- migrate:down
DROP FUNCTION public.owner_metrics_calculate;

ALTER TABLE repos DROP COLUMN owner_id;

DROP TABLE owner_metrics;

DROP TABLE owners;