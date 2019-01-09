require "mosquito"

class Taskmaster::Mosquito
  include Taskmaster::Adapter

  def enqueue(job : Job, **options)
    MosquitoJob.new(name: job.class.to_s, args: job.to_json).enqueue
  end
end

class MosquitoJob < Mosquito::QueuedJob
  params(name : String, args : String)

  def rescheduleable?
    false
  end

  def perform
    # TODO: Improve hackish integration of Moquito job
    case name
    when "Service::ImportCatalog"
      job = Service::ImportCatalog.from_json(args)
    when "Service::ImportShard"
      job = Service::ImportShard.from_json(args)
    when "Service::LinkDependencies"
      job = Service::LinkDependencies.from_json(args)
    when "Service::LinkMissingDependencies"
      job = Service::LinkMissingDependencies.from_json(args)
    when "Service::OrderReleases"
      job = Service::OrderReleases.from_json(args)
    when "Service::SyncRelease"
      job = Service::SyncRelease.from_json(args)
    when "Service::SyncRepo"
      job = Service::SyncRepo.from_json(args)
    when "Service::SyncRepos"
      job = Service::SyncRepos.from_json(args)
    else
      raise "Unknown job name  #{name}"
    end

    log "performing #{name} #{args}"

    job.perform
  end
end
