require "spec"
require "../../src/service/link_missing_dependencies"
require "../support/db"
require "../../src/dependency"

describe Service::LinkDependencies do
  it "schedules LinkDependencies jobs" do
    transaction do |db|
      release_id = Factory.create_release(db)
      Factory.create_dependency(db, release_id, "test", JSON.parse(%({"git":"mock:test"})))

      service = Service::LinkMissingDependencies.new

      service.link_missing_dependencies(db)

      enqueued_jobs.should eq [{"Service::LinkDependencies", %({"release_id":#{release_id}})}]
    end
  end

  it "does not schedule LinkDependencies jobs when all resolved" do
    transaction do |db|
      test_shard_id = Factory.create_shard(db, "test")
      test_repo_id = Factory.create_repo(db, test_shard_id, Repo::Ref.new("git", "mock:test"))
      release_id = Factory.create_release(db)
      Factory.create_dependency(db, release_id, "test", JSON.parse(%({"git":"mock:test"})), shard_id: test_shard_id)

      service = Service::LinkMissingDependencies.new

      service.link_missing_dependencies(db)

      enqueued_jobs.empty?.should be_true
    end
  end

  it "does not schedule LinkDependencies jobs when resolvable = false" do
    transaction do |db|
      release_id = Factory.create_release(db)
      Factory.create_dependency(db, release_id, "test", JSON.parse(%({"git":"mock:test"})), resolvable: false)

      service = Service::LinkMissingDependencies.new

      service.link_missing_dependencies(db)

      enqueued_jobs.empty?.should be_true
    end
  end
end
