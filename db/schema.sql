--
-- PostgreSQL database dump
--

-- Dumped from database version 11.1 (Ubuntu 11.1-1.pgdg16.04+1)
-- Dumped by pg_dump version 11.1 (Ubuntu 11.1-1.pgdg16.04+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
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
-- Name: dependency_scope; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.dependency_scope AS ENUM (
    'runtime',
    'development'
);


ALTER TYPE public.dependency_scope OWNER TO postgres;

--
-- Name: repo_resolver; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.repo_resolver AS ENUM (
    'git',
    'github',
    'gitlab',
    'bitbucket'
);


ALTER TYPE public.repo_resolver OWNER TO postgres;

--
-- Name: repo_role; Type: TYPE; Schema: public; Owner: postgres
--

CREATE TYPE public.repo_role AS ENUM (
    'canonical',
    'mirror',
    'legacy'
);


ALTER TYPE public.repo_role OWNER TO postgres;

--
-- Name: ensure_only_one_latest_release_trigger(); Type: FUNCTION; Schema: public; Owner: postgres
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


ALTER FUNCTION public.ensure_only_one_latest_release_trigger() OWNER TO postgres;

--
-- Name: trigger_set_timestamp(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.trigger_set_timestamp() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION public.trigger_set_timestamp() OWNER TO postgres;

SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: dependencies; Type: TABLE; Schema: public; Owner: postgres
--

CREATE TABLE public.dependencies (
    release_id bigint NOT NULL,
    shard_id bigint,
    name public.citext NOT NULL,
    spec jsonb NOT NULL,
    scope public.dependency_scope NOT NULL,
    resolvable boolean NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE public.dependencies OWNER TO postgres;

--
-- Name: releases; Type: TABLE; Schema: public; Owner: postgres
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


ALTER TABLE public.releases OWNER TO postgres;

--
-- Name: releases_id_seq; Type: SEQUENCE; Schema: public; Owner: postgres
--

CREATE SEQUENCE public.releases_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.releases_id_seq OWNER TO postgres;

--
-- Name: releases_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: postgres
--

ALTER SEQUENCE public.releases_id_seq OWNED BY public.releases.id;


--
-- Name: repos; Type: TABLE; Schema: public; Owner: shards_toolbox
--

CREATE TABLE public.repos (
    id bigint NOT NULL,
    shard_id bigint NOT NULL,
    resolver public.repo_resolver NOT NULL,
    url public.citext NOT NULL,
    role public.repo_role DEFAULT 'canonical'::public.repo_role NOT NULL,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL,
    synced_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT repos_resolvers_service_url CHECK (((NOT (resolver = ANY (ARRAY['github'::public.repo_resolver, 'gitlab'::public.repo_resolver, 'bitbucket'::public.repo_resolver]))) OR ((url OPERATOR(public.~) '^[A-Za-z0-9_\-.]{1,100}/[A-Za-z0-9_\-.]{1,100}$'::public.citext) AND (url OPERATOR(public.!~~) '%.git'::public.citext))))
);


ALTER TABLE public.repos OWNER TO shards_toolbox;

--
-- Name: repos_id_seq; Type: SEQUENCE; Schema: public; Owner: shards_toolbox
--

CREATE SEQUENCE public.repos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.repos_id_seq OWNER TO shards_toolbox;

--
-- Name: repos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: shards_toolbox
--

ALTER SEQUENCE public.repos_id_seq OWNED BY public.repos.id;


--
-- Name: shards; Type: TABLE; Schema: public; Owner: shards_toolbox
--

CREATE TABLE public.shards (
    id bigint NOT NULL,
    name public.citext NOT NULL,
    qualifier public.citext DEFAULT ''::public.citext NOT NULL,
    description text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT shards_name_check CHECK ((name OPERATOR(public.~) '^[A-Za-z0-9_\-.]{1,100}$'::text)),
    CONSTRAINT shards_qualifier_check CHECK ((qualifier OPERATOR(public.~) '^[A-Za-z0-9_\-.]{0,100}$'::public.citext))
);


ALTER TABLE public.shards OWNER TO shards_toolbox;

--
-- Name: shards_dependencies; Type: VIEW; Schema: public; Owner: postgres
--

CREATE VIEW public.shards_dependencies AS
 SELECT DISTINCT dependent.id AS shard,
    shards.id AS depends_on
   FROM (((public.shards
     JOIN public.dependencies ON ((dependencies.shard_id = shards.id)))
     JOIN public.releases ON (((releases.id = dependencies.release_id) AND releases.latest)))
     JOIN public.shards dependent ON ((dependent.id = releases.shard_id)));


ALTER TABLE public.shards_dependencies OWNER TO postgres;

--
-- Name: shards_id_seq; Type: SEQUENCE; Schema: public; Owner: shards_toolbox
--

CREATE SEQUENCE public.shards_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE public.shards_id_seq OWNER TO shards_toolbox;

--
-- Name: shards_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: shards_toolbox
--

ALTER SEQUENCE public.shards_id_seq OWNED BY public.shards.id;


--
-- Name: releases id; Type: DEFAULT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.releases ALTER COLUMN id SET DEFAULT nextval('public.releases_id_seq'::regclass);


--
-- Name: repos id; Type: DEFAULT; Schema: public; Owner: shards_toolbox
--

ALTER TABLE ONLY public.repos ALTER COLUMN id SET DEFAULT nextval('public.repos_id_seq'::regclass);


--
-- Name: shards id; Type: DEFAULT; Schema: public; Owner: shards_toolbox
--

ALTER TABLE ONLY public.shards ALTER COLUMN id SET DEFAULT nextval('public.shards_id_seq'::regclass);


--
-- Name: dependencies dependencies_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dependencies
    ADD CONSTRAINT dependencies_uniq UNIQUE (release_id, name);


--
-- Name: releases releases_position_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.releases
    ADD CONSTRAINT releases_position_uniq UNIQUE (shard_id, "position") DEFERRABLE INITIALLY DEFERRED;


--
-- Name: releases releases_version_uniq; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.releases
    ADD CONSTRAINT releases_version_uniq UNIQUE (shard_id, version);


--
-- Name: repos repos_pkey; Type: CONSTRAINT; Schema: public; Owner: shards_toolbox
--

ALTER TABLE ONLY public.repos
    ADD CONSTRAINT repos_pkey PRIMARY KEY (id);


--
-- Name: repos repos_url_uniq; Type: CONSTRAINT; Schema: public; Owner: shards_toolbox
--

ALTER TABLE ONLY public.repos
    ADD CONSTRAINT repos_url_uniq UNIQUE (url, resolver);


--
-- Name: shards shards_name_unique; Type: CONSTRAINT; Schema: public; Owner: shards_toolbox
--

ALTER TABLE ONLY public.shards
    ADD CONSTRAINT shards_name_unique UNIQUE (name, qualifier);


--
-- Name: shards shards_pkey; Type: CONSTRAINT; Schema: public; Owner: shards_toolbox
--

ALTER TABLE ONLY public.shards
    ADD CONSTRAINT shards_pkey PRIMARY KEY (id);


--
-- Name: releases specs_pkey; Type: CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.releases
    ADD CONSTRAINT specs_pkey PRIMARY KEY (id);


--
-- Name: releases_shard_id_latest_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX releases_shard_id_latest_idx ON public.releases USING btree (shard_id, latest) WHERE (latest = true);


--
-- Name: repos_shard_id_role_idx; Type: INDEX; Schema: public; Owner: shards_toolbox
--

CREATE UNIQUE INDEX repos_shard_id_role_idx ON public.repos USING btree (shard_id, role) WHERE (role = 'canonical'::public.repo_role);


--
-- Name: releases releases_only_one_latest_release; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER releases_only_one_latest_release BEFORE INSERT OR UPDATE OF latest ON public.releases FOR EACH ROW WHEN ((new.latest = true)) EXECUTE PROCEDURE public.ensure_only_one_latest_release_trigger();


--
-- Name: releases set_timestamp; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_timestamp BEFORE UPDATE ON public.releases FOR EACH ROW EXECUTE PROCEDURE public.trigger_set_timestamp();


--
-- Name: shards set_timestamp; Type: TRIGGER; Schema: public; Owner: shards_toolbox
--

CREATE TRIGGER set_timestamp BEFORE UPDATE ON public.shards FOR EACH ROW EXECUTE PROCEDURE public.trigger_set_timestamp();


--
-- Name: dependencies set_timestamp; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER set_timestamp BEFORE UPDATE ON public.dependencies FOR EACH ROW EXECUTE PROCEDURE public.trigger_set_timestamp();


--
-- Name: repos set_timestamp; Type: TRIGGER; Schema: public; Owner: shards_toolbox
--

CREATE TRIGGER set_timestamp BEFORE UPDATE ON public.repos FOR EACH ROW EXECUTE PROCEDURE public.trigger_set_timestamp();


--
-- Name: dependencies depdendencies_shard_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dependencies
    ADD CONSTRAINT depdendencies_shard_id_fkey FOREIGN KEY (shard_id) REFERENCES public.shards(id);


--
-- Name: dependencies dependencies_release_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.dependencies
    ADD CONSTRAINT dependencies_release_id_fkey FOREIGN KEY (release_id) REFERENCES public.releases(id) ON DELETE CASCADE;


--
-- Name: repos repos_shard_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: shards_toolbox
--

ALTER TABLE ONLY public.repos
    ADD CONSTRAINT repos_shard_id_fkey FOREIGN KEY (shard_id) REFERENCES public.shards(id) ON DELETE CASCADE;


--
-- Name: releases specs_shard_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY public.releases
    ADD CONSTRAINT specs_shard_id_fkey FOREIGN KEY (shard_id) REFERENCES public.shards(id);


--
-- Name: FUNCTION trigger_set_timestamp(); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION public.trigger_set_timestamp() TO shards_toolbox;


--
-- Name: TABLE dependencies; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.dependencies TO shards_toolbox;


--
-- Name: TABLE releases; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE public.releases TO shards_toolbox;


--
-- Name: SEQUENCE releases_id_seq; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE public.releases_id_seq TO shards_toolbox;


--
-- PostgreSQL database dump complete
--

