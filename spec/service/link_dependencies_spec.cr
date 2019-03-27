require "spec"
require "../../src/service/link_dependencies"
require "../support/db"
require "../support/jobs"
require "../../src/dependency"

describe Service::LinkDependencies do
  it "links dependencies" do
    transaction do |db|
      test_shard_id = Factory.create_shard(db, "test")
      test_repo_id = Factory.create_repo(db, test_shard_id, Repo::Ref.new("git", "mock:test"))
      release_id = Factory.create_release(db)
      Factory.create_dependency(db, release_id, "test", JSON.parse(%({"git":"mock:test"})))
      Factory.create_dependency(db, release_id, "unresolvable", JSON.parse(%({"local":"unresolvable"})))
      Factory.create_dependency(db, release_id, "unregistered", JSON.parse(%({"git":"unregistered"})))

      service = Service::LinkDependencies.new(release_id)

      service.link_dependencies(db)

      results = db.connection.query_all <<-SQL, as: {Int64?, String, Bool}
        SELECT
          shard_id, name::text, resolvable
        FROM dependencies
        ORDER BY name
        SQL

      results.should eq [
        {test_shard_id, "test", true},
        {nil, "unregistered", true},
        {nil, "unresolvable", false},
      ]

      enqueued_jobs.should eq [{"Service::ImportShard", %({"repo_ref":{"resolver":"git","url":"unregistered"}})}]
    end
  end
end
