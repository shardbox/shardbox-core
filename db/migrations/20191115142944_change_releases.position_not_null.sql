-- migrate:up
UPDATE releases
SET
  position = COALESCE((SELECT MAX(position) + 1 FROM releases AS r WHERE r.shard_id = releases.shard_id), 0)
WHERE
  position IS NULL;
ALTER TABLE releases ALTER COLUMN position SET NOT NULL;

-- migrate:down
ALTER TABLE releases ALTER COLUMN position DROP NOT NULL;
