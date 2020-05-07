-- migrate:up

ALTER TABLE shards
  ADD COLUMN merged_with bigint,
  ADD CONSTRAINT shards_merged_with_fk FOREIGN KEY (merged_with) REFERENCES shards(id),
  ADD CONSTRAINT shards_merged_with_archived_at CHECK (merged_with IS NULL OR (archived_at IS NOT NULL AND categories = '{}')),
  DROP CONSTRAINT shards_name_unique,
  ADD CONSTRAINT shards_name_unique UNIQUE (name, qualifier) DEFERRABLE INITIALLY IMMEDIATE
;

-- Update all existing archived shards to point to the shard they were merged into
UPDATE shards
SET
  merged_with = log.shard_id
FROM activity_log log
WHERE log.event = 'import_catalog:mirror:switched'
  AND log.metadata->>'old_role' = 'canonical'
  AND log.metadata->'old_shard_id' <> 'null'
  AND shards.id = (metadata->'old_shard_id')::bigint
;

-- Remove dependencies on the merged shard (they should be picked up by the merge target)
DELETE FROM shard_dependencies
USING shards
WHERE shards.id = shard_id
  AND shards.merged_with IS NOT NULL
;

-- Switch qualifiers if a merged shard has the empty qualifier
SET CONSTRAINTS shards_name_unique DEFERRED;
UPDATE shards
  SET qualifier = main.qualifier
FROM shards main
WHERE shards.merged_with = main.id
  AND shards.name = main.name
  AND shards.qualifier = ''
;
UPDATE shards
  SET qualifier = ''
FROM shards merged
WHERE shards.id = merged.merged_with
  AND shards.name = merged.name
  AND shards.qualifier = merged.qualifier
;

-- migrate:down

ALTER TABLE shards
  DROP COLUMN merged_with,
  DROP CONSTRAINT shards_name_unique,
  ADD CONSTRAINT shards_name_unique UNIQUE (name, qualifier)
;
