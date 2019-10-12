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
  catalog_path = ARGV.shift? || "./catalog"
  uri = URI.parse(catalog_path)
  if uri.scheme
    catalog_path = Service::ImportCatalog.checkout_catalog(uri)
  end
  Service::ImportCatalog.new(catalog_path).perform_later
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

  Service::SyncRepos.new(hours.hours, ratio).perform_later
when "help"
  show_help(STDOUT)
when "sync_repo"
  arg = ARGV.shift
  if repo_id = arg.to_i64?
    Service::SyncRepo.new(repo_id).perform_later
  else
    Service::SyncRepo.new(Repo::Ref.parse(arg)).perform_later
  end
when "update_metrics"
  Service::UpdateShardMetrics.new.perform_later
when "loop"
  Service::WorkerLoop.new.perform_later
else
  STDERR.puts "unknown command #{command.inspect}"
  show_help(STDERR)
  exit 1
end

queue.run
