-- migrate:up
ALTER TABLE repos
  ADD CONSTRAINT repos_shard_id_null_role CHECK (shard_id IS NOT NULL OR role = 'canonical' OR role = 'obsolete'),
  ADD CONSTRAINT repos_obsolete_role_shard_id_null CHECK (role <> 'obsolete' OR shard_id IS NULL);

-- migrate:down
ALTER TABLE repos
  DROP CONSTRAINT repos_shard_id_null_role,
  DROP CONSTRAINT repos_obsolete_role_shard_id_null;

