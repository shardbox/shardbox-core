require "spec"
require "../../src/service/sync_dependencies"
require "../../src/repo"
require "../../src/repo/resolver"
require "../support/db"
require "../support/mock_resolver"

private def query_dependencies_with_repo(db)
  db.connection.query_all <<-SQL, as: {String, JSON::Any, String, Int64?, String, String, String}
    SELECT
      name::text, spec, scope::text,
      repos.shard_id, repos.resolver::text, repos.url::text, repos.role::text
    FROM
      dependencies
    JOIN
      repos ON repo_id = repos.id
    SQL
end

describe Service::SyncDependencies do
  describe "#sync_dependency" do
    context "non-existing repo" do
      it "creates dependency and repo" do
        transaction do |db|
          release_id = Factory.create_release(db)

          spec = JSON.parse(%({"git":"foo"}))

          service = Service::SyncDependencies.new(db, release_id)
          service.sync_dependency(Dependency.new("foo", spec))

          results = query_dependencies_with_repo(db)

          results.should eq [
            {"foo", spec, "runtime", nil, "git", "foo", "canonical"},
          ]

          db.repos_pending_sync.map(&.ref).should eq [Repo::Ref.new("git", "foo")]
        end
      end

      it "updates dependency" do
        transaction do |db|
          release_id = Factory.create_release(db)

          service = Service::SyncDependencies.new(db, release_id)

          spec_foo = JSON.parse(%({"git":"foo"}))
          service.sync_dependency(Dependency.new("foo", spec_foo))
          spec_bar = JSON.parse(%({"git":"bar"}))
          service.sync_dependency(Dependency.new("foo", spec_bar, :development))

          results = query_dependencies_with_repo(db)

          results.should eq [
            {"foo", spec_bar, "development", nil, "git", "bar", "canonical"},
          ]

          db.repos_pending_sync.map(&.ref).should eq [Repo::Ref.new("git", "foo"), Repo::Ref.new("git", "bar")]
        end
      end
    end

    context "existing repo" do
      it "creates dependency and links repo" do
        transaction do |db|
          release_id = Factory.create_release(db)
          shard_id = Factory.create_shard(db, "foo")
          repo_foo = db.create_repo Repo.new(Repo::Ref.new("git", "foo"), nil, :canonical, synced_at: Time.utc)
          repo_bar = db.create_repo Repo.new(Repo::Ref.new("git", "bar"), shard_id, :canonical, synced_at: Time.utc)

          service = Service::SyncDependencies.new(db, release_id)

          spec_foo = JSON.parse(%({"git":"foo"}))
          service.sync_dependency(Dependency.new("foo", spec_foo))
          spec_bar = JSON.parse(%({"git":"bar"}))
          service.sync_dependency(Dependency.new("bar", spec_bar))

          results = query_dependencies_with_repo(db)

          results.should eq [
            {"foo", spec_foo, "runtime", nil, "git", "foo", "canonical"},
            {"bar", spec_bar, "runtime", shard_id, "git", "bar", "canonical"},
          ]

          db.repos_pending_sync.should eq [] of Repo
        end
      end

      it "updates dependency" do
        transaction do |db|
          release_id = Factory.create_release(db)
          shard_id = Factory.create_shard(db, "bar")
          repo_foo = db.create_repo Repo.new(Repo::Ref.new("git", "foo"), nil, :canonical, synced_at: Time.utc)
          repo_bar = db.create_repo Repo.new(Repo::Ref.new("git", "bar"), shard_id, :canonical, synced_at: Time.utc)

          service = Service::SyncDependencies.new(db, release_id)

          spec_foo = JSON.parse(%({"git":"foo"}))
          service.sync_dependency(Dependency.new("foo", spec_foo))
          spec_bar = JSON.parse(%({"git":"bar"}))
          service.sync_dependency(Dependency.new("foo", spec_bar, :development))

          results = query_dependencies_with_repo(db)

          results.should eq [
            {"foo", spec_bar, "development", shard_id, "git", "bar", "canonical"},
          ]

          db.repos_pending_sync.should eq [] of Repo
        end
      end
    end
  end

  it "#sync_dependencies" do
    transaction do |db|
      release_id = Factory.create_release(db)

      run_spec = JSON.parse(%({"git":"run"}))
      dev_spec = JSON.parse(%({"git":"dev"}))
      dependencies = [
        Dependency.new("run_dependency", run_spec),
        Dependency.new("dev_dependency", dev_spec, :development),
      ]

      service = Service::SyncDependencies.new(db, release_id)
      service.sync_dependencies(dependencies)

      results = query_dependencies_with_repo(db)

      results.should eq [
        {"run_dependency", run_spec, "runtime", nil, "git", "run", "canonical"},
        {"dev_dependency", dev_spec, "development", nil, "git", "dev", "canonical"},
      ]

      run_spec2 = JSON.parse(%({"git":"run2"}))
      new_dependencies = [
        Dependency.new("run_dependency", run_spec),
        Dependency.new("run_dependency2", run_spec2),
      ]

      service.sync_dependencies(new_dependencies)
      results = query_dependencies_with_repo(db)

      results.should eq [
        {"run_dependency", run_spec, "runtime", nil, "git", "run", "canonical"},
        {"run_dependency2", run_spec2, "runtime", nil, "git", "run2", "canonical"},
      ]
    end
  end
end
