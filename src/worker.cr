require "./service/import_catalog"
require "./service/sync_repos"
require "./service/update_shard_metrics"
require "./service/update_owner_metrics"
require "./service/worker_loop"
require "./raven"
require "uri"
require "log"

Log.setup do |config|
  stdout = Log::IOBackend.new
  config.bind "*", :info, stdout
  config.bind "service.*", :debug, stdout
  config.bind "shardbox.activity", :info, stdout
  config.bind "db.*", :info, stdout

  raven = Raven::LogBackend.new(
    capture_exceptions: true,
    record_breadcrumbs: true,
  )
  config.bind "*", :warn, raven
end

unless ENV.has_key?("GITHUB_TOKEN")
  puts "Missing environment variable GITHUB_TOKEN"
  exit 1
end

# Disable git asking for credentials when cloning a repository. It's probably been deleted.
# TODO: Remove this workaround (probably use libgit2 bindings instead)
ENV["GIT_ASKPASS"] = "/usr/bin/test"

def show_help(io)
  io.puts "shards-toolbox worker"
  io.puts "commands:"
  io.puts "  import_catalog [<path>]         import catalog data from <path> (default: ./catalog)"
  io.puts "  sync_repos [<hours> [<ratio>]]  syncs repos not updated in last <hours> (<ratio> 0.0-1.0)"
  io.puts "  sync_repo <repo_ref>            sync a single repo identified by <repo_ref>"
  io.puts "  update_metrics                  update shard metrics (should be run once per day)"
  io.puts "  loop                            run worker loop to schedule sync and update tasks"
  io.puts "  help                            show usage instructions"
end

def sync_all_pending_repos
  Shardbox::Log.info { "Syncing pending repos" }
  ShardsDB.connect do |db|
    Service::SyncRepos.new(db).sync_all_pending_repos
  end
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

  sync_all_pending_repos
when "sync_repos"
  hours = nil
  ratio = nil
  if arg = ARGV.shift?
    hours = arg.to_i
    if arg = ARGV.shift?
      ratio = arg.to_f
    end
  end
  hours ||= ENV["SHARDBOX_WORKER_SYNC_REPO_HOURS"]?.try(&.to_i) || 24
  ratio ||= ENV["SHARDBOX_WORKER_SYNC_REPO_RATIO"]?.try(&.to_f) || 10.0 / hours

  ShardsDB.transaction do |db|
    Service::SyncRepos.new(db, hours.hours, ratio).perform
  end
when "help"
  show_help(STDOUT)
when "sync_repo"
  arg = ARGV.shift

  ShardsDB.transaction do |db|
    Service::SyncRepo.new(db, Repo::Ref.parse(arg)).perform
  end

  sync_all_pending_repos
when "sync_pending_repos"
  limit = ARGV.shift?.try(&.to_i)
  ShardsDB.connect do |db|
    Service::SyncRepos.new(db).sync_all_pending_repos(limit)
  end
when "update_metrics"
  ShardsDB.transaction do |db|
    Service::UpdateShardMetrics.new(db).perform
    Service::UpdateOwnerMetrics.new(db).perform
  end
when "loop"
  Service::WorkerLoop.new.perform
else
  STDERR.puts "unknown command #{command.inspect}"
  show_help(STDERR)
  exit 1
end
