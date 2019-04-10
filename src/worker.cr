require "taskmaster"
require "taskmaster/adapter/queue"
require "./service/import_catalog"
require "./service/sync_repos"
require "./raven"

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
end

case command = ARGV.shift?
when "import_catalog"
  catalog_path = ARGV.shift? || "./catalog"
  Service::ImportCatalog.new(catalog_path).perform_later
when "sync_repos"
  hours = 24
  ratio = 1.0/24
  if arg = ARGV.shift?
    hours = arg.to_i
    if arg = ARGV.shift?
      ratio = arg.to_f
    end
  end

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
else
  STDERR.puts "unknown command #{command.inspect}"
  show_help(STDERR)
  exit 1
end

queue.run
