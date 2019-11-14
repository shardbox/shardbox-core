require "taskmaster"
require "taskmaster/adapter/queue"
require "./service/import_catalog"
require "./service/sync_repos"
require "./service/update_shard_metrics"
require "./service/worker_loop"
require "./raven"
require "uri"

# Disable git asking for credentials when cloning a repository. It's probably been deleted.
# TODO: Remove this workaround (probably use libgit2 bindings instead)
ENV["GIT_ASKPASS"] = "/usr/bin/test"

queue = Taskmaster::Queue.new
Taskmaster.adapter = queue

def show_help(io)
  io.puts "shards-toolbox worker"
  io.puts "commands:"
  io.puts "  import_catalog [path]        import catalog data from [path] (default: ./catalog)"
  io.puts "  sync_repos [hours [ratio]]   syncs repos not updated in last [hours] ([ratio] 0.0-1.0)"
  io.puts "  update_metrics               update shard metrics (should be run once per day)"
end

case command = ARGV.shift?
when "import_catalog"
  catalog_path = ARGV.shift? || ENV["SHARDBOX_CATALOG"]?
  unless catalog_path
    abort "No catalog path specified. Either provide program argument or environment variable SHARDBOX_CATALOG"
  end
  ShardsDB.transaction do |db|
    service = Service::ImportCatalog.new(db, catalog_path)
    service.perform
  end
  exit 0
when "sync_repos"
  hours = 24
  ratio = nil
  if arg = ARGV.shift?
    hours = arg.to_i
    if arg = ARGV.shift?
      ratio = arg.to_f
    end
  end
  ratio ||= 2.0 / hours

  ShardsDB.transaction do |db|
    Service::SyncRepos.new(db, hours.hours, ratio).perform
  end
  queue.run
  exit 0
when "help"
  show_help(STDOUT)
  exit 0
when "sync_repo"
  arg = ARGV.shift

  service = Service::SyncRepo.new(Repo::Ref.parse(arg))
when "update_metrics"
  service = Service::UpdateShardMetrics.new
when "loop"
  service = Service::WorkerLoop.new
else
  STDERR.puts "unknown command #{command.inspect}"
  show_help(STDERR)
  exit 1
end

service.perform

# Run pending jobs
queue.run
