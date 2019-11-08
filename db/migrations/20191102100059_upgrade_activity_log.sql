-- migrate:up
ALTER TABLE sync_log RENAME TO activity_log;

ALTER TABLE activity_log
  ADD COLUMN shard_id bigint REFERENCES shards(id),
  ALTER COLUMN repo_id DROP NOT NULL;

ALTER SEQUENCE sync_log_id_seq RENAME TO activity_log_id_seq;

ALTER TABLE activity_log RENAME CONSTRAINT sync_log_pkey TO activity_log_pkey;
ALTER TABLE activity_log RENAME CONSTRAINT sync_log_repo_id_fkey TO activity_log_repo_id_fkey;

UPDATE activity_log
SET
  event = 'sync_repo:' || event
;

-- migrate:down

UPDATE activity_log
SET
  event = substring(event FROM 11)
WHERE
  starts_with(event, 'sync_repo:')
;

ALTER TABLE activity_log RENAME CONSTRAINT activity_log_repo_id_fkey TO sync_log_repo_id_fkey;
ALTER TABLE activity_log RENAME CONSTRAINT activity_log_pkey TO sync_log_pkey;

ALTER SEQUENCE activity_log_id_seq RENAME TO sync_log_id_seq;

ALTER TABLE activity_log
  ALTER COLUMN repo_id SET NOT NULL,
  DROP COLUMN shard_id;

ALTER TABLE activity_log RENAME TO sync_log;
