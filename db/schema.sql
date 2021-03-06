SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: citext; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;


--
-- Name: EXTENSION citext; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION citext IS 'data type for case-insensitive character strings';


--
-- Name: dependency_scope; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.dependency_scope AS ENUM (
    'runtime',
    'development'
);


--
-- Name: repo_resolver; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.repo_resolver AS ENUM (
    'git',
    'github',
    'gitlab',
    'bitbucket'
);


--
-- Name: repo_role; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.repo_role AS ENUM (
    'canonical',
    'mirror',
    'legacy',
    'obsolete'
);


--
-- Name: ensure_only_one_latest_release_trigger(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ensure_only_one_latest_release_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- nothing to do if updating the row currently enabled
    IF (TG_OP = 'UPDATE' AND OLD.latest = true) THEN
        RETURN NEW;
    END IF;

    -- disable the currently enabled row
    EXECUTE format('UPDATE %I.%I SET latest = null WHERE shard_id = %s AND latest = true;', TG_TABLE_SCHEMA, TG_TABLE_NAME, NEW.shard_id);

    -- enable new row
    NEW.latest := true;
    RETURN NEW;
END;
$$;


--
-- Name: owner_metrics_calculate(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.owner_metrics_calculate(curr_owner_id bigint) RETURNS void
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


--
-- Name: shard_dependencies_materialize(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.shard_dependencies_materialize() RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
      TRUNCATE shard_dependencies;

      INSERT INTO
        shard_dependencies
      SELECT DISTINCT
        releases.shard_id,
        repos.shard_id AS depends_on,
        repos.id AS depends_on_repo_id,
        dependencies.scope
      FROM
        dependencies
      JOIN
        repos ON repos.id = dependencies.repo_id
      JOIN
        releases ON releases.id = dependencies.release_id AND releases.latest
      ON CONFLICT ON CONSTRAINT shard_dependencies_uniq DO NOTHING
      ;
END;
$$;


--
-- Name: shard_metrics_calculate(bigint); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.shard_metrics_calculate(curr_shard_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN

  CREATE TEMPORARY TABLE dependents
  AS
    SELECT
      shard_id, scope
    FROM
      shard_dependencies
    WHERE
      depends_on = curr_shard_id
  ;
  CREATE TEMPORARY TABLE tmp_dependencies
  AS
    SELECT
      depends_on, scope
    FROM
      shard_dependencies
    WHERE
      shard_id = curr_shard_id
  ;

  INSERT INTO shard_metrics
    (
      shard_id,
      dependents_count, dev_dependents_count, transitive_dependents_count,
      dependencies_count, dev_dependencies_count, transitive_dependencies_count,
      likes_count, watchers_count, forks_count,
      popularity
    )
  SELECT
    curr_shard_id AS shard_id,
    (
      SELECT
        COUNT(*)
      FROM
        dependents
      WHERE
        scope = 'runtime'
    ) AS dependents_count,
    (
      SELECT
        COUNT(*)
      FROM
        dependents
      WHERE
        scope <> 'runtime'
    ) AS dev_dependents_count,
    tdc.transitive_dependents_count,
    (
      SELECT
        COUNT(*)
      FROM
        tmp_dependencies
      WHERE
        scope = 'runtime'
    ) AS dependencies_count,
    (
      SELECT
        COUNT(*)
      FROM
        tmp_dependencies
      WHERE
        scope <> 'runtime'
    ) AS dev_dependencies_count,
    (
      WITH RECURSIVE transitive_dependencies AS (
        SELECT
          curr_shard_id AS shard_id, depends_on
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
    ) AS transitive_dependencies_count,
    repo_stats.*,
    COALESCE(
      POWER(
        POWER(COALESCE(tdc.transitive_dependents_count, 0) + 1, 1.5) *
        POWER(COALESCE(repo_stats.likes_count, 0) + 1, 1.3) *
        POWER(COALESCE(repo_stats.watchers_count, 0) + 1, 1.0) *
        POWER(COALESCE(repo_stats.forks_count, 0) + 1, .3),
        1.0/4
      ),
      1.0
    ) AS popularity
    FROM
      (
        SELECT
          COALESCE((metadata->'stargazers_count')::int, 0) AS likes_count,
          COALESCE((metadata->'watchers_count')::int, 0) AS watchers_count,
          COALESCE((metadata->'forks_count')::int, 0) AS forks_count
        FROM
          repos
        WHERE
          shard_id = curr_shard_id AND role = 'canonical'
      ) AS repo_stats,
      (
        WITH RECURSIVE transitive_dependents AS (
          SELECT
            shard_id, curr_shard_id AS depends_on
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
  ;

  DROP TABLE dependents;
  DROP TABLE tmp_dependencies;
END;
$$;


--
-- Name: shard_metrics_current_trigger(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.shard_metrics_current_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF (TG_OP = 'DELETE') THEN
    DELETE FROM public.shard_metrics_current WHERE shard_id = OLD.shard_id;
  ELSE
    DELETE FROM public.shard_metrics_current WHERE shard_id = NEW.shard_id;

    INSERT INTO
      public.shard_metrics_current
    VALUES
      (NEW.*);
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: shards_categories_trigger(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.shards_categories_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    id bigint;
BEGIN
    IF (TG_OP = 'UPDATE' OR TG_OP = 'INSERT') THEN
        FOREACH id IN ARRAY NEW.categories LOOP
            EXECUTE format('UPDATE %I.categories SET entries_count = (SELECT COUNT(*) FROM public.shards WHERE categories @> ARRAY[%s]::bigint[]) WHERE id = %s', TG_TABLE_SCHEMA, id, id);
        END LOOP;
    END IF;

    IF (TG_OP = 'UPDATE' OR TG_OP = 'DELETE') THEN
        FOREACH id IN ARRAY OLD.categories LOOP
            EXECUTE format('UPDATE %I.categories SET entries_count = (SELECT COUNT(*) FROM public.shards WHERE categories @> ARRAY[%s]::bigint[]) WHERE id = %s', TG_TABLE_SCHEMA, id, id);
        END LOOP;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: shards_refresh_dependents(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.shards_refresh_dependents() RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  shards_cursor NO SCROLL CURSOR FOR
    SELECT
        id, name
    FROM
        shards;
  curr_shard RECORD;
BEGIN
  OPEN shards_cursor;

  LOOP
    FETCH shards_cursor INTO curr_shard;
    EXIT WHEN NOT FOUND;

    CREATE TEMPORARY TABLE dependents
    AS
      SELECT
        shard_id, scope
      FROM
        shard_dependencies
      WHERE
        depends_on = curr_shard.id
    ;
    CREATE TEMPORARY TABLE tmp_dependencies
    AS
      SELECT
        depends_on, scope
      FROM
        shard_dependencies
      WHERE
        shard_id = curr_shard.id
    ;

    INSERT INTO shard_metrics
    SELECT
        curr_shard.id AS shard_id,
        (
            SELECT
                COUNT(*)
            FROM
                dependents
            WHERE
                scope = 'runtime'
        ) AS dependents_count,
        (
            SELECT
                COUNT(*)
            FROM
                dependents
            WHERE
                scope <> 'runtime'
        ) AS dev_dependents_count,
        (
            WITH RECURSIVE transitive_dependents AS (
                SELECT
                    shard_id, curr_shard.id AS depends_on
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
                COUNT(*)
            FROM
            (
                SELECT DISTINCT
                shard_id
                FROM
                transitive_dependents
            ) AS d
        ) AS transitive_dependents_count,
        (
            SELECT
                COUNT(*)
            FROM
                tmp_dependencies
            WHERE
                scope = 'runtime'
        ) AS dependencies_count,
        (
            SELECT
                COUNT(*)
            FROM
                tmp_dependencies
            WHERE
                scope <> 'runtime'
        ) AS dev_dependencies_count,
        (
            WITH RECURSIVE transitive_dependencies AS (
                SELECT
                    curr_shard.id AS shard_id, depends_on
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
        ) AS transitive_dependencies_count
    ;

    DROP TABLE dependents;
    DROP TABLE tmp_dependencies;
  END LOOP;

  CLOSE shards_cursor;
END;
$$;


--
-- Name: trigger_set_timestamp(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trigger_set_timestamp() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: activity_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activity_log (
    id bigint NOT NULL,
    repo_id bigint,
    event text NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    shard_id bigint
);


--
-- Name: activity_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.activity_log ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.activity_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.categories (
    id bigint NOT NULL,
    name public.citext NOT NULL,
    description text,
    entries_count integer DEFAULT 0 NOT NULL,
    slug public.citext NOT NULL
);


--
-- Name: categories_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.categories ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.categories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: dependencies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.dependencies (
    release_id bigint NOT NULL,
    name public.citext NOT NULL,
    repo_id bigint,
    spec jsonb NOT NULL,
    scope public.dependency_scope NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: files; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.files (
    id bigint NOT NULL,
    release_id bigint NOT NULL,
    path text NOT NULL,
    content text
);


--
-- Name: files_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.files ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.files_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: owner_metrics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.owner_metrics (
    id bigint NOT NULL,
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


--
-- Name: owner_metrics_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.owner_metrics ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.owner_metrics_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: owners; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.owners (
    id bigint NOT NULL,
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


--
-- Name: owners_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.owners ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.owners_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: releases; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.releases (
    id bigint NOT NULL,
    shard_id bigint NOT NULL,
    version character varying NOT NULL,
    revision_info jsonb NOT NULL,
    spec jsonb NOT NULL,
    "position" integer NOT NULL,
    latest boolean,
    released_at timestamp with time zone NOT NULL,
    yanked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT releases_latest_check CHECK ((latest <> false)),
    CONSTRAINT releases_version_check CHECK ((((version)::text ~ '^[0-9]+(\.[0-9a-zA-Z]+)*(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'::text) OR ((version)::text = 'HEAD'::text)))
);


--
-- Name: releases_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.releases ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.releases_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: repos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.repos (
    id bigint NOT NULL,
    shard_id bigint,
    resolver public.repo_resolver NOT NULL,
    url public.citext NOT NULL,
    role public.repo_role DEFAULT 'canonical'::public.repo_role NOT NULL,
    synced_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    sync_failed_at timestamp with time zone,
    owner_id bigint,
    CONSTRAINT repos_obsolete_role_shard_id_null CHECK (((role <> 'obsolete'::public.repo_role) OR (shard_id IS NULL))),
    CONSTRAINT repos_resolvers_service_url CHECK (((NOT (resolver = ANY (ARRAY['github'::public.repo_resolver, 'gitlab'::public.repo_resolver, 'bitbucket'::public.repo_resolver]))) OR ((url OPERATOR(public.~) '^[A-Za-z0-9_\-.]{1,100}/[A-Za-z0-9_\-.]{1,100}$'::public.citext) AND (url OPERATOR(public.!~~) '%.git'::public.citext)))),
    CONSTRAINT repos_shard_id_null_role CHECK (((shard_id IS NOT NULL) OR (role = 'canonical'::public.repo_role) OR (role = 'obsolete'::public.repo_role)))
);


--
-- Name: repos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.repos ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.repos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version character varying(255) NOT NULL
);


--
-- Name: shard_dependencies; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shard_dependencies (
    shard_id bigint NOT NULL,
    depends_on bigint,
    depends_on_repo_id bigint NOT NULL,
    scope public.dependency_scope NOT NULL
);


--
-- Name: shard_metrics; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shard_metrics (
    id bigint NOT NULL,
    shard_id bigint NOT NULL,
    popularity real,
    likes_count integer,
    watchers_count integer,
    forks_count integer,
    clones_count integer,
    dependents_count integer,
    transitive_dependents_count integer,
    dev_dependents_count integer,
    transitive_dependencies_count integer,
    dev_dependencies_count integer,
    dependencies_count integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: shard_metrics_current; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shard_metrics_current (
    id bigint NOT NULL,
    shard_id bigint NOT NULL,
    popularity real,
    likes_count integer,
    watchers_count integer,
    forks_count integer,
    clones_count integer,
    dependents_count integer,
    transitive_dependents_count integer,
    dev_dependents_count integer,
    transitive_dependencies_count integer,
    dev_dependencies_count integer,
    dependencies_count integer,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: shard_metrics_current_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shard_metrics_current ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shard_metrics_current_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shard_metrics_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shard_metrics ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shard_metrics_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: shards; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.shards (
    id bigint NOT NULL,
    name public.citext NOT NULL,
    qualifier public.citext DEFAULT ''::public.citext NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    categories bigint[] DEFAULT '{}'::bigint[] NOT NULL,
    archived_at timestamp with time zone,
    merged_with bigint,
    CONSTRAINT shards_merged_with_archived_at CHECK (((merged_with IS NULL) OR ((archived_at IS NOT NULL) AND (categories = '{}'::bigint[])))),
    CONSTRAINT shards_name_check CHECK ((name OPERATOR(public.~) '^[A-Za-z0-9_\-.]{1,100}$'::text)),
    CONSTRAINT shards_qualifier_check CHECK ((qualifier OPERATOR(public.~) '^[A-Za-z0-9_\-.]{0,100}$'::public.citext))
);


--
-- Name: shards_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.shards ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.shards_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: activity_log activity_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_log
    ADD CONSTRAINT activity_log_pkey PRIMARY KEY (id);


--
-- Name: categories categories_name_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_name_uniq UNIQUE (name);


--
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (id);


--
-- Name: categories categories_slug_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_slug_key UNIQUE (slug);


--
-- Name: categories categories_slug_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_slug_uniq UNIQUE (slug);


--
-- Name: dependencies dependencies_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dependencies
    ADD CONSTRAINT dependencies_uniq UNIQUE (release_id, name);


--
-- Name: files files_release_id_path_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.files
    ADD CONSTRAINT files_release_id_path_uniq UNIQUE (release_id, path);


--
-- Name: categories name_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT name_uniq UNIQUE (name);


--
-- Name: owner_metrics owner_metrics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owner_metrics
    ADD CONSTRAINT owner_metrics_pkey PRIMARY KEY (id);


--
-- Name: owners owners_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owners
    ADD CONSTRAINT owners_pkey PRIMARY KEY (id);


--
-- Name: owners owners_resolver_slug_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owners
    ADD CONSTRAINT owners_resolver_slug_uniq UNIQUE (resolver, slug);


--
-- Name: releases releases_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.releases
    ADD CONSTRAINT releases_pkey PRIMARY KEY (id);


--
-- Name: releases releases_position_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.releases
    ADD CONSTRAINT releases_position_uniq UNIQUE (shard_id, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: releases releases_version_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.releases
    ADD CONSTRAINT releases_version_uniq UNIQUE (shard_id, version);


--
-- Name: repos repos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.repos
    ADD CONSTRAINT repos_pkey PRIMARY KEY (id);


--
-- Name: repos repos_url_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.repos
    ADD CONSTRAINT repos_url_uniq UNIQUE (url, resolver);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: shard_dependencies shard_dependencies_uniq; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shard_dependencies
    ADD CONSTRAINT shard_dependencies_uniq UNIQUE (depends_on, shard_id, scope);


--
-- Name: shard_metrics_current shard_metrics_current_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shard_metrics_current
    ADD CONSTRAINT shard_metrics_current_pkey PRIMARY KEY (id);


--
-- Name: shard_metrics shard_metrics_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shard_metrics
    ADD CONSTRAINT shard_metrics_pkey PRIMARY KEY (id);


--
-- Name: shards shards_name_unique; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shards
    ADD CONSTRAINT shards_name_unique UNIQUE (name, qualifier) DEFERRABLE;


--
-- Name: shards shards_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shards
    ADD CONSTRAINT shards_pkey PRIMARY KEY (id);


--
-- Name: releases_shard_id_latest_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX releases_shard_id_latest_idx ON public.releases USING btree (shard_id, latest) WHERE (latest = true);


--
-- Name: repos_shard_id_role_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX repos_shard_id_role_idx ON public.repos USING btree (shard_id, role) WHERE (role = 'canonical'::public.repo_role);


--
-- Name: repos_synced_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX repos_synced_at ON public.repos USING btree (synced_at NULLS FIRST) INCLUDE (shard_id, role);


--
-- Name: shard_dependencies_depends_on; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shard_dependencies_depends_on ON public.shard_dependencies USING btree (depends_on, scope) INCLUDE (shard_id);


--
-- Name: shard_metrics_current_shard_id_uniq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX shard_metrics_current_shard_id_uniq ON public.shard_metrics_current USING btree (shard_id);


--
-- Name: shards_categories; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX shards_categories ON public.shards USING gin (categories);


--
-- Name: shards categories_entries_count; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER categories_entries_count AFTER INSERT OR DELETE OR UPDATE OF categories ON public.shards FOR EACH ROW EXECUTE FUNCTION public.shards_categories_trigger();


--
-- Name: releases releases_only_one_latest_release; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER releases_only_one_latest_release BEFORE INSERT OR UPDATE OF latest ON public.releases FOR EACH ROW WHEN ((new.latest = true)) EXECUTE FUNCTION public.ensure_only_one_latest_release_trigger();


--
-- Name: dependencies set_timestamp; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_timestamp BEFORE UPDATE ON public.dependencies FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: owners set_timestamp; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_timestamp BEFORE UPDATE ON public.owners FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: releases set_timestamp; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_timestamp BEFORE UPDATE ON public.releases FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: repos set_timestamp; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_timestamp BEFORE UPDATE ON public.repos FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: shards set_timestamp; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER set_timestamp BEFORE UPDATE ON public.shards FOR EACH ROW EXECUTE FUNCTION public.trigger_set_timestamp();


--
-- Name: shard_metrics shard_metrics_current; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER shard_metrics_current AFTER INSERT OR DELETE OR UPDATE ON public.shard_metrics FOR EACH ROW EXECUTE FUNCTION public.shard_metrics_current_trigger();


--
-- Name: activity_log activity_log_repo_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_log
    ADD CONSTRAINT activity_log_repo_id_fkey FOREIGN KEY (repo_id) REFERENCES public.repos(id);


--
-- Name: activity_log activity_log_shard_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_log
    ADD CONSTRAINT activity_log_shard_id_fkey FOREIGN KEY (shard_id) REFERENCES public.shards(id);


--
-- Name: dependencies dependencies_release_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dependencies
    ADD CONSTRAINT dependencies_release_id_fkey FOREIGN KEY (release_id) REFERENCES public.releases(id) ON DELETE CASCADE;


--
-- Name: dependencies dependencies_repo_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.dependencies
    ADD CONSTRAINT dependencies_repo_id_fkey FOREIGN KEY (repo_id) REFERENCES public.repos(id);


--
-- Name: files files_release_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.files
    ADD CONSTRAINT files_release_id_fkey FOREIGN KEY (release_id) REFERENCES public.releases(id);


--
-- Name: owner_metrics owner_metrics_owner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.owner_metrics
    ADD CONSTRAINT owner_metrics_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.owners(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: releases releases_shard_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.releases
    ADD CONSTRAINT releases_shard_id_fkey FOREIGN KEY (shard_id) REFERENCES public.shards(id) ON DELETE CASCADE;


--
-- Name: repos repos_owner_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.repos
    ADD CONSTRAINT repos_owner_id_fkey FOREIGN KEY (owner_id) REFERENCES public.owners(id);


--
-- Name: repos repos_shard_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.repos
    ADD CONSTRAINT repos_shard_id_fkey FOREIGN KEY (shard_id) REFERENCES public.shards(id) ON DELETE CASCADE;


--
-- Name: shard_dependencies shard_dependencies_depends_on_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shard_dependencies
    ADD CONSTRAINT shard_dependencies_depends_on_fkey FOREIGN KEY (depends_on) REFERENCES public.shards(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: shard_dependencies shard_dependencies_depends_on_repo_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shard_dependencies
    ADD CONSTRAINT shard_dependencies_depends_on_repo_id_fkey FOREIGN KEY (depends_on_repo_id) REFERENCES public.repos(id);


--
-- Name: shard_dependencies shard_dependencies_shard_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shard_dependencies
    ADD CONSTRAINT shard_dependencies_shard_id_fkey FOREIGN KEY (shard_id) REFERENCES public.shards(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: shard_metrics_current shard_metrics_current_shard_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shard_metrics_current
    ADD CONSTRAINT shard_metrics_current_shard_id_fkey FOREIGN KEY (shard_id) REFERENCES public.shards(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: shard_metrics shard_metrics_shard_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shard_metrics
    ADD CONSTRAINT shard_metrics_shard_id_fkey FOREIGN KEY (shard_id) REFERENCES public.shards(id) ON DELETE CASCADE DEFERRABLE;


--
-- Name: shards shards_merged_with_fk; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.shards
    ADD CONSTRAINT shards_merged_with_fk FOREIGN KEY (merged_with) REFERENCES public.shards(id);


--
-- PostgreSQL database dump complete
--


--
-- Dbmate schema migrations
--

INSERT INTO public.schema_migrations (version) VALUES
    ('1'),
    ('20191012163928'),
    ('20191102100059'),
    ('20191106093828'),
    ('20191115142944'),
    ('20191122122940'),
    ('20200503132444'),
    ('20200506215505');
