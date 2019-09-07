--
-- PostgreSQL database dump
--

-- Dumped from database version 11.5 (Ubuntu 11.5-1.pgdg16.04+1)
-- Dumped by pg_dump version 11.5 (Ubuntu 11.5-1.pgdg16.04+1)

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
-- Name: citext; Type: EXTENSION; Schema: -; Owner:
--

CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;


--
-- Name: EXTENSION citext; Type: COMMENT; Schema: -; Owner:
--

COMMENT ON EXTENSION citext IS 'data type for case-insensitive character strings';


--
-- Name: dependency_scope; Type: TYPE; Schema: public; Owner: shardbox
--

CREATE TYPE public.dependency_scope AS ENUM (
    'runtime',
    'development'
);


ALTER TYPE public.dependency_scope OWNER TO shardbox;

--
-- Name: repo_resolver; Type: TYPE; Schema: public; Owner: shardbox
--

CREATE TYPE public.repo_resolver AS ENUM (
    'git',
    'github',
    'gitlab',
    'bitbucket'
);


ALTER TYPE public.repo_resolver OWNER TO shardbox;

--
-- Name: repo_role; Type: TYPE; Schema: public; Owner: shardbox
--

CREATE TYPE public.repo_role AS ENUM (
    'canonical',
    'mirror',
    'legacy',
    'obsolete'
);


ALTER TYPE public.repo_role OWNER TO shardbox;

--
-- Name: ensure_only_one_latest_release_trigger(); Type: FUNCTION; Schema: public; Owner: shardbox
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


ALTER FUNCTION public.ensure_only_one_latest_release_trigger() OWNER TO shardbox;

--
-- Name: shard_dependencies_materialize(); Type: FUNCTION; Schema: public; Owner: shardbox
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
        dependencies.scope
      FROM
        dependencies
      JOIN
        repos ON repos.id = dependencies.repo_id
      JOIN
        releases ON releases.id = dependencies.release_id AND releases.latest
      WHERE
        repos.shard_id IS NOT NULL
      ON CONFLICT ON CONSTRAINT shard_dependencies_uniq DO NOTHING
      ;
END;
$$;


ALTER FUNCTION public.shard_dependencies_materialize() OWNER TO shardbox;

--
-- Name: shard_metrics_calculate(bigint); Type: FUNCTION; Schema: public; Owner: shardbox
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
      shards_dependencies
    WHERE
      depends_on = curr_shard_id
  ;
  CREATE TEMPORARY TABLE tmp_dependencies
  AS
    SELECT
      depends_on, scope
    FROM
      shards_dependencies
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
          shards_dependencies d
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
            shards_dependencies d
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


ALTER FUNCTION public.shard_metrics_calculate(curr_shard_id bigint) OWNER TO shardbox;

--
-- Name: shard_metrics_current_trigger(); Type: FUNCTION; Schema: public; Owner: shardbox
--

CREATE FUNCTION public.shard_metrics_current_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF (TG_OP = 'DELETE') THEN
    DELETE FROM shard_metrics_current WHERE shard_id = OLD.shard_id;
  ELSE
    DELETE FROM shard_metrics_current WHERE shard_id = NEW.shard_id;

    INSERT INTO
      shard_metrics_current
    VALUES
      (NEW.*);
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION public.shard_metrics_current_trigger() OWNER TO shardbox;

--
-- Name: shard_metrics_materialize(); Type: FUNCTION; Schema: public; Owner: shardbox
--

CREATE FUNCTION public.shard_metrics_materialize() RETURNS void
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

    RAISE NOTICE 'curr_shard %', curr_shard;

    CREATE TEMPORARY TABLE dependents
    AS
      SELECT
        shard_id, scope
      FROM
        shards_dependencies
      WHERE
        depends_on = curr_shard.id
    ;
    CREATE TEMPORARY TABLE tmp_dependencies
    AS
      SELECT
        depends_on, scope
      FROM
        shards_dependencies
      WHERE
        shard_id = curr_shard.id
    ;

    INSERT INTO shard_metrics
        (
            shard_id,
            dependents_count, dev_dependents_count, transitive_dependents_count,
            dependencies_count, dev_dependencies_count, transitive_dependencies_count
        )
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
                    shards_dependencies d
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
                    shards_dependencies d
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


ALTER FUNCTION public.shard_metrics_materialize() OWNER TO shardbox;

--
-- Name: shards_categories_trigger(); Type: FUNCTION; Schema: public; Owner: shardbox
--

CREATE FUNCTION public.shards_categories_trigger() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    id bigint;
BEGIN
    IF (TG_OP = 'UPDATE' OR TG_OP = 'INSERT') THEN
        FOREACH id IN ARRAY NEW.categories LOOP
            EXECUTE format('UPDATE %I.categories SET entries_count = (SELECT COUNT(*) FROM shards WHERE categories @> ARRAY[%s]::bigint[]) WHERE id = %s', TG_TABLE_SCHEMA, id, id);
        END LOOP;
    END IF;

    IF (TG_OP = 'UPDATE' OR TG_OP = 'DELETE') THEN
        FOREACH id IN ARRAY OLD.categories LOOP
            EXECUTE format('UPDATE %I.categories SET entries_count = (SELECT COUNT(*) FROM shards WHERE categories @> ARRAY[%s]::bigint[]) WHERE id = %s', TG_TABLE_SCHEMA, id, id);
        END LOOP;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION public.shards_categories_trigger() OWNER TO shardbox;

--
-- Name: shards_refresh_dependents(); Type: FUNCTION; Schema: public; Owner: shardbox
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
        shards_dependencies
      WHERE
        depends_on = curr_shard.id
    ;
    CREATE TEMPORARY TABLE tmp_dependencies
    AS
      SELECT
        depends_on, scope
      FROM
        shards_dependencies
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
                    shards_dependencies d
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
                    shards_dependencies d
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


ALTER FUNCTION public.shards_refresh_dependents() OWNER TO shardbox;

--
-- Name: trigger_set_timestamp(); Type: FUNCTION; Schema: public; Owner: shardbox
--

CREATE FUNCTION public.trigger_set_timestamp() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.trigger_set_timestamp() OWNER TO shardbox;

SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: categories; Type: TABLE; Schema: public; Owner: shardbox
--

CREATE TABLE public.categories (
    id bigint NOT NULL,
    name public.citext NOT NULL,
    description text,
    entries_count integer DEFAULT 0 NOT NULL,
    slug public.citext NOT NULL
);


ALTER TABLE public.categories OWNER TO shardbox;

--
-- Name: categories_id_seq; Type: SEQUENCE; Schema: public; Owner: shardbox
--

CREATE SEQUENCE public.categories_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.categories_id_seq OWNER TO shardbox;

--
-- Name: categories_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: shardbox
--

ALTER SEQUENCE public.categories_id_seq OWNED BY public.categories.id;


--
-- Name: dependencies; Type: TABLE; Schema: public; Owner: shardbox
--

CREATE TABLE public.dependencies (
    release_id bigint NOT NULL,
    shard_id_deprecated bigint,
    name public.citext NOT NULL,
    spec jsonb NOT NULL,
    scope public.dependency_scope NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    repo_id bigint
);


ALTER TABLE public.dependencies OWNER TO shardbox;

--
-- Name: releases; Type: TABLE; Schema: public; Owner: shardbox
--

CREATE TABLE public.releases (
    id bigint NOT NULL,
    shard_id bigint NOT NULL,
    version character varying NOT NULL,
    revision_info jsonb NOT NULL,
    spec jsonb NOT NULL,
    "position" integer,
    latest boolean,
    released_at timestamp with time zone NOT NULL,
    yanked_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT releases_latest_check CHECK ((latest <> false)),
    CONSTRAINT releases_version_check CHECK ((((version)::text ~ '^[0-9]+(\.[0-9a-zA-Z]+)*(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'::text) OR ((version)::text = 'HEAD'::text)))
);


ALTER TABLE public.releases OWNER TO shardbox;

--
-- Name: releases_id_seq; Type: SEQUENCE; Schema: public; Owner: shardbox
--

CREATE SEQUENCE public.releases_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.releases_id_seq OWNER TO shardbox;

--
-- Name: releases_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: shardbox
--

ALTER SEQUENCE public.releases_id_seq OWNED BY public.releases.id;


--
-- Name: repos; Type: TABLE; Schema: public; Owner: shardbox
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
    CONSTRAINT repos_resolvers_service_url CHECK (((NOT (resolver = ANY (ARRAY['github'::public.repo_resolver, 'gitlab'::public.repo_resolver, 'bitbucket'::public.repo_resolver]))) OR ((url OPERATOR(public.~) '^[A-Za-z0-9_\-.]{1,100}/[A-Za-z0-9_\-.]{1,100}$'::public.citext) AND (url OPERATOR(public.!~~) '%.git'::public.citext))))
);


ALTER TABLE public.repos OWNER TO shardbox;

--
-- Name: repos_id_seq; Type: SEQUENCE; Schema: public; Owner: shardbox
--

CREATE SEQUENCE public.repos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.repos_id_seq OWNER TO shardbox;

--
-- Name: repos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: shardbox
--

ALTER SEQUENCE public.repos_id_seq OWNED BY public.repos.id;


--
-- Name: shard_dependencies; Type: TABLE; Schema: public; Owner: shardbox
--

CREATE TABLE public.shard_dependencies (
    shard_id bigint NOT NULL,
    depends_on bigint NOT NULL,
    scope public.dependency_scope NOT NULL
);


ALTER TABLE public.shard_dependencies OWNER TO shardbox;

--
-- Name: shard_metrics; Type: TABLE; Schema: public; Owner: shardbox
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


ALTER TABLE public.shard_metrics OWNER TO shardbox;

--
-- Name: shard_metrics_current; Type: TABLE; Schema: public; Owner: shardbox
--

CREATE TABLE public.shard_metrics_current (
)
INHERITS (public.shard_metrics);


ALTER TABLE public.shard_metrics_current OWNER TO shardbox;

--
-- Name: shard_metrics_id_seq; Type: SEQUENCE; Schema: public; Owner: shardbox
--

CREATE SEQUENCE public.shard_metrics_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.shard_metrics_id_seq OWNER TO shardbox;

--
-- Name: shard_metrics_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: shardbox
--

ALTER SEQUENCE public.shard_metrics_id_seq OWNED BY public.shard_metrics.id;


--
-- Name: shards; Type: TABLE; Schema: public; Owner: shardbox
--

CREATE TABLE public.shards (
    id bigint NOT NULL,
    name public.citext NOT NULL,
    qualifier public.citext DEFAULT ''::public.citext NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    categories bigint[] DEFAULT '{}'::bigint[] NOT NULL,
    CONSTRAINT shards_name_check CHECK ((name OPERATOR(public.~) '^[A-Za-z0-9_\-.]{1,100}$'::text)),
    CONSTRAINT shards_qualifier_check CHECK ((qualifier OPERATOR(public.~) '^[A-Za-z0-9_\-.]{0,100}$'::public.citext))
);


ALTER TABLE public.shards OWNER TO shardbox;

--
-- Name: shards_dependencies; Type: VIEW; Schema: public; Owner: shardbox
--

CREATE VIEW public.shards_dependencies AS
 SELECT DISTINCT repos.shard_id AS depends_on,
    releases.shard_id,
    dependencies.scope
   FROM ((public.dependencies
     JOIN public.repos ON ((repos.id = dependencies.repo_id)))
     JOIN public.releases ON (((releases.id = dependencies.release_id) AND releases.latest)));


ALTER TABLE public.shards_dependencies OWNER TO shardbox;

--
-- Name: shards_deps; Type: MATERIALIZED VIEW; Schema: public; Owner: shardbox
--

CREATE MATERIALIZED VIEW public.shards_deps AS
 SELECT DISTINCT dependent.id AS shard,
    shards.id AS depends_on,
    dependencies.scope
   FROM (((public.shards
     JOIN public.dependencies ON ((dependencies.shard_id_deprecated = shards.id)))
     JOIN public.releases ON (((releases.id = dependencies.release_id) AND releases.latest)))
     JOIN public.shards dependent ON ((dependent.id = releases.shard_id)))
  WITH NO DATA;


ALTER TABLE public.shards_deps OWNER TO shardbox;

--
-- Name: shards_id_seq; Type: SEQUENCE; Schema: public; Owner: shardbox
--

CREATE SEQUENCE public.shards_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.shards_id_seq OWNER TO shardbox;

--
-- Name: shards_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: shardbox
--

ALTER SEQUENCE public.shards_id_seq OWNED BY public.shards.id;


--
-- Name: shards_stats; Type: TABLE; Schema: public; Owner: shardbox
--

CREATE TABLE public.shards_stats (
    id bigint NOT NULL,
    watchers integer,
    forks integer,
    popularity real DEFAULT 1 NOT NULL,
    dependents integer,
    score real DEFAULT 1 NOT NULL
);


ALTER TABLE public.shards_stats OWNER TO shardbox;

--
-- Name: categories id; Type: DEFAULT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.categories ALTER COLUMN id SET DEFAULT nextval('public.categories_id_seq'::regclass);


--
-- Name: releases id; Type: DEFAULT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.releases ALTER COLUMN id SET DEFAULT nextval('public.releases_id_seq'::regclass);


--
-- Name: repos id; Type: DEFAULT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.repos ALTER COLUMN id SET DEFAULT nextval('public.repos_id_seq'::regclass);


--
-- Name: shard_metrics id; Type: DEFAULT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.shard_metrics ALTER COLUMN id SET DEFAULT nextval('public.shard_metrics_id_seq'::regclass);


--
-- Name: shard_metrics_current id; Type: DEFAULT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.shard_metrics_current ALTER COLUMN id SET DEFAULT NULL;


--
-- Name: shard_metrics_current created_at; Type: DEFAULT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.shard_metrics_current ALTER COLUMN created_at SET DEFAULT NULL;


--
-- Name: shards id; Type: DEFAULT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.shards ALTER COLUMN id SET DEFAULT nextval('public.shards_id_seq'::regclass);


--
-- Name: categories categories_name_uniq; Type: CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_name_uniq UNIQUE (name);


--
-- Name: categories categories_slug_key; Type: CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_slug_key UNIQUE (slug);


--
-- Name: categories categories_slug_uniq; Type: CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_slug_uniq UNIQUE (slug);


--
-- Name: dependencies dependencies_uniq; Type: CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.dependencies
    ADD CONSTRAINT dependencies_uniq UNIQUE (release_id, name);


--
-- Name: categories name_uniq; Type: CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT name_uniq UNIQUE (name);


--
-- Name: releases releases_position_uniq; Type: CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.releases
    ADD CONSTRAINT releases_position_uniq UNIQUE (shard_id, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: releases releases_version_uniq; Type: CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.releases
    ADD CONSTRAINT releases_version_uniq UNIQUE (shard_id, version);


--
-- Name: repos repos_pkey; Type: CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.repos
    ADD CONSTRAINT repos_pkey PRIMARY KEY (id);


--
-- Name: repos repos_url_uniq; Type: CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.repos
    ADD CONSTRAINT repos_url_uniq UNIQUE (url, resolver);


--
-- Name: shard_dependencies shard_dependencies_uniq; Type: CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.shard_dependencies
    ADD CONSTRAINT shard_dependencies_uniq UNIQUE (depends_on, shard_id, scope);


--
-- Name: shards shards_name_unique; Type: CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.shards
    ADD CONSTRAINT shards_name_unique UNIQUE (name, qualifier);


--
-- Name: shards shards_pkey; Type: CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.shards
    ADD CONSTRAINT shards_pkey PRIMARY KEY (id);


--
-- Name: shards_stats shards_stats_id_key; Type: CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.shards_stats
    ADD CONSTRAINT shards_stats_id_key UNIQUE (id);


--
-- Name: releases specs_pkey; Type: CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.releases
    ADD CONSTRAINT specs_pkey PRIMARY KEY (id);


--
-- Name: releases_shard_id_latest_idx; Type: INDEX; Schema: public; Owner: shardbox
--

CREATE UNIQUE INDEX releases_shard_id_latest_idx ON public.releases USING btree (shard_id, latest) WHERE (latest = true);


--
-- Name: repos_shard_id_role_idx; Type: INDEX; Schema: public; Owner: shardbox
--

CREATE UNIQUE INDEX repos_shard_id_role_idx ON public.repos USING btree (shard_id, role) WHERE (role = 'canonical'::public.repo_role);


--
-- Name: repos_synced_at; Type: INDEX; Schema: public; Owner: shardbox
--

CREATE INDEX repos_synced_at ON public.repos USING btree (synced_at NULLS FIRST) INCLUDE (shard_id, role);


--
-- Name: shard_dependencies_depends_on; Type: INDEX; Schema: public; Owner: shardbox
--

CREATE INDEX shard_dependencies_depends_on ON public.shard_dependencies USING btree (depends_on, scope) INCLUDE (shard_id);


--
-- Name: shard_metrics_current_shard_id_uniq; Type: INDEX; Schema: public; Owner: shardbox
--

CREATE UNIQUE INDEX shard_metrics_current_shard_id_uniq ON public.shard_metrics_current USING btree (shard_id);


--
-- Name: shards_categories; Type: INDEX; Schema: public; Owner: shardbox
--

CREATE INDEX shards_categories ON public.shards USING gin (categories);


--
-- Name: shards categories_entries_count; Type: TRIGGER; Schema: public; Owner: shardbox
--

CREATE TRIGGER categories_entries_count AFTER INSERT OR DELETE OR UPDATE OF categories ON public.shards FOR EACH ROW EXECUTE PROCEDURE public.shards_categories_trigger();


--
-- Name: releases releases_only_one_latest_release; Type: TRIGGER; Schema: public; Owner: shardbox
--

CREATE TRIGGER releases_only_one_latest_release BEFORE INSERT OR UPDATE OF latest ON public.releases FOR EACH ROW WHEN ((new.latest = true)) EXECUTE PROCEDURE public.ensure_only_one_latest_release_trigger();


--
-- Name: releases set_timestamp; Type: TRIGGER; Schema: public; Owner: shardbox
--

CREATE TRIGGER set_timestamp BEFORE UPDATE ON public.releases FOR EACH ROW EXECUTE PROCEDURE public.trigger_set_timestamp();


--
-- Name: shards set_timestamp; Type: TRIGGER; Schema: public; Owner: shardbox
--

CREATE TRIGGER set_timestamp BEFORE UPDATE ON public.shards FOR EACH ROW EXECUTE PROCEDURE public.trigger_set_timestamp();


--
-- Name: dependencies set_timestamp; Type: TRIGGER; Schema: public; Owner: shardbox
--

CREATE TRIGGER set_timestamp BEFORE UPDATE ON public.dependencies FOR EACH ROW EXECUTE PROCEDURE public.trigger_set_timestamp();


--
-- Name: repos set_timestamp; Type: TRIGGER; Schema: public; Owner: shardbox
--

CREATE TRIGGER set_timestamp BEFORE UPDATE ON public.repos FOR EACH ROW EXECUTE PROCEDURE public.trigger_set_timestamp();


--
-- Name: shard_metrics shard_metrics_current; Type: TRIGGER; Schema: public; Owner: shardbox
--

CREATE TRIGGER shard_metrics_current AFTER INSERT OR DELETE OR UPDATE ON public.shard_metrics FOR EACH ROW EXECUTE PROCEDURE public.shard_metrics_current_trigger();


--
-- Name: dependencies dependencies_release_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.dependencies
    ADD CONSTRAINT dependencies_release_id_fkey FOREIGN KEY (release_id) REFERENCES public.releases(id) ON DELETE CASCADE;


--
-- Name: dependencies dependencies_repo_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.dependencies
    ADD CONSTRAINT dependencies_repo_id_fkey FOREIGN KEY (repo_id) REFERENCES public.repos(id);


--
-- Name: repos repos_shard_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.repos
    ADD CONSTRAINT repos_shard_id_fkey FOREIGN KEY (shard_id) REFERENCES public.shards(id) ON DELETE CASCADE;


--
-- Name: shard_dependencies shard_dependencies_depends_on_fkey; Type: FK CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.shard_dependencies
    ADD CONSTRAINT shard_dependencies_depends_on_fkey FOREIGN KEY (depends_on) REFERENCES public.shards(id) ON DELETE CASCADE;


--
-- Name: shard_dependencies shard_dependencies_shard_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.shard_dependencies
    ADD CONSTRAINT shard_dependencies_shard_id_fkey FOREIGN KEY (shard_id) REFERENCES public.shards(id) ON DELETE CASCADE;


--
-- Name: shard_metrics shard_metrics_shard_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: shardbox
--

ALTER TABLE ONLY public.shard_metrics
    ADD CONSTRAINT shard_metrics_shard_id_fkey FOREIGN KEY (shard_id) REFERENCES public.shards(id) ON DELETE CASCADE;


--
-- Name: FUNCTION trigger_set_timestamp(); Type: ACL; Schema: public; Owner: shardbox
--

GRANT ALL ON FUNCTION public.trigger_set_timestamp() TO shards_toolbox;


--
-- Name: TABLE categories; Type: ACL; Schema: public; Owner: shardbox
--

GRANT ALL ON TABLE public.categories TO shards_toolbox;


--
-- Name: SEQUENCE categories_id_seq; Type: ACL; Schema: public; Owner: shardbox
--

GRANT ALL ON SEQUENCE public.categories_id_seq TO shards_toolbox;


--
-- Name: TABLE dependencies; Type: ACL; Schema: public; Owner: shardbox
--

GRANT ALL ON TABLE public.dependencies TO shards_toolbox;


--
-- Name: TABLE releases; Type: ACL; Schema: public; Owner: shardbox
--

GRANT ALL ON TABLE public.releases TO shards_toolbox;


--
-- Name: SEQUENCE releases_id_seq; Type: ACL; Schema: public; Owner: shardbox
--

GRANT ALL ON SEQUENCE public.releases_id_seq TO shards_toolbox;


--
-- Name: TABLE shards_dependencies; Type: ACL; Schema: public; Owner: shardbox
--

GRANT ALL ON TABLE public.shards_dependencies TO shards_toolbox;


--
-- PostgreSQL database dump complete
--

