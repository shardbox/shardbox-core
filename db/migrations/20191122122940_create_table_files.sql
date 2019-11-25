-- migrate:up
CREATE TABLE files (
    id bigint GENERATED BY DEFAULT AS IDENTITY,
    release_id bigint NOT NULL REFERENCES releases(id),
    path text NOT NULL,
    content text
);

CREATE UNIQUE INDEX files_release_id_path_idx ON public.files USING btree (release_id, path);
ALTER TABLE files
  ADD CONSTRAINT files_release_id_path_uniq UNIQUE USING INDEX files_release_id_path_idx;

-- migrate:down
DROP TABLE files;
