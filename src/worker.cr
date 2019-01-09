require "taskmaster"
require "./service/import_catalog"
require "./service/sync_repos"
require "./service/link_missing_dependencies"
require "./mosquito"

# Disable git asking for credentials when cloning a repository. It's probably been deleted.
# TODO: Remove this workaround (probably use libgit2 bindings instead)
ENV["GIT_ASKPASS"] = "/usr/bin/test"

Taskmaster.adapter = Taskmaster::Mosquito.new

def enqueue_job(job)
  puts "Enqueueing job #{job.class} #{job.to_json}."

  job.perform_later

  puts "Run `#{PROGRAM_NAME}` to execute job queue."
end

case command = ARGV.shift?
when "import_catalog"
  enqueue_job(Service::ImportCatalog.new("catalog"))
when "sync_repos"
  if age = ARGV.first?
    age = age.to_i.hours
  else
    age = 24.hours
  end
  enqueue_job(Service::SyncRepos.new(age))
when "link_missing_dependencies"
  enqueue_job(Service::LinkMissingDependencies.new)
when Nil
  Mosquito::Runner.start
else
  abort "unknown command #{command.inspect}"
end
