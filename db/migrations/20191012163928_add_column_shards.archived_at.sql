-- migrate:up
ALTER TABLE public.shards ADD COLUMN archived_at timestamptz;

-- migrate:down
ALTER TABLE public.shards DROP COLUMN archived_at;
