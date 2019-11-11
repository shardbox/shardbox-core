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
  describe "#add_dependency" do
    context "non-existing repo" do
      it "creates dependency and repo" do
        transaction do |db|
          shard_id = Factory.create_shard(db)
          release_version = "0.1.0"
          release_id = Factory.create_release(db, version: release_version, shard_id: shard_id)

          spec = JSON.parse(%({"git":"foo"}))

          service = Service::SyncDependencies.new(db, release_id)
          service.add_dependency(Dependency.new("foo", spec))

          results = query_dependencies_with_repo(db)

          results.should eq [
            {"foo", spec, "runtime", nil, "git", "foo", "canonical"},
          ]

          db.repos_pending_sync.map(&.ref).should eq [Repo::Ref.new("git", "foo")]

          repo_id = db.get_repo_id("git", "foo")
          db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
            {"sync_dependencies:created", repo_id, shard_id, {"name" => "foo", "scope" => "runtime", "release" => release_version}},
          ]
        end
      end
    end

    describe "#update_dependency" do
      it "overrides homonymous dependency name" do
        transaction do |db|
          shard_id = Factory.create_shard(db)
          release_version = "0.1.0"
          release_id = Factory.create_release(db, version: release_version, shard_id: shard_id)

          service = Service::SyncDependencies.new(db, release_id)

          spec_bar = JSON.parse(%({"git":"bar"}))
          service.add_dependency(Dependency.new("foo", spec_bar, :development))
          spec_foo = JSON.parse(%({"git":"foo"}))
          service.add_dependency(Dependency.new("foo", spec_foo))

          results = query_dependencies_with_repo(db)

          results.should eq [
            {"foo", spec_foo, "runtime", nil, "git", "foo", "canonical"},
          ]

          db.repos_pending_sync.map(&.ref).should eq [Repo::Ref.new("git", "bar"), Repo::Ref.new("git", "foo")]

          foo_repo_id = db.get_repo_id("git", "foo")
          bar_repo_id = db.get_repo_id("git", "bar")
          db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
            {"sync_dependencies:created", bar_repo_id, shard_id, {"name" => "foo", "scope" => "development", "release" => release_version}},
            {"sync_dependencies:duplicate", foo_repo_id, shard_id, {"name" => "foo", "scope" => "runtime", "release" => release_version}},
            {"sync_dependencies:updated", foo_repo_id, shard_id, {"name" => "foo", "scope" => "runtime", "release" => release_version}},
          ]
        end
      end
    end

    context "existing repo" do
      it "creates dependency and links repo" do
        transaction do |db|
          shard_id = Factory.create_shard(db)
          release_id = Factory.create_release(db, shard_id: shard_id)
          bar_shard_id = Factory.create_shard(db, "bar")
          repo_foo = db.create_repo Repo.new(Repo::Ref.new("git", "foo"), nil, :canonical, synced_at: Time.utc)
          repo_bar = db.create_repo Repo.new(Repo::Ref.new("git", "bar"), bar_shard_id, :canonical, synced_at: Time.utc)

          service = Service::SyncDependencies.new(db, release_id)

          spec_foo = JSON.parse(%({"git":"foo"}))
          service.add_dependency(Dependency.new("foo", spec_foo))
          spec_bar = JSON.parse(%({"git":"bar"}))
          service.add_dependency(Dependency.new("bar", spec_bar))

          results = query_dependencies_with_repo(db)

          results.should eq [
            {"foo", spec_foo, "runtime", nil, "git", "foo", "canonical"},
            {"bar", spec_bar, "runtime", bar_shard_id, "git", "bar", "canonical"},
          ]

          db.repos_pending_sync.should eq [] of Repo

          db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
            {"sync_dependencies:created", repo_foo, shard_id, {"name" => "foo", "scope" => "runtime", "release" => "0.1.0"}},
            {"sync_dependencies:created", repo_bar, shard_id, {"name" => "bar", "scope" => "runtime", "release" => "0.1.0"}},
          ]
        end
      end

      it "updates dependency" do
        transaction do |db|
          home_shard = Factory.create_shard(db, "qux")
          release_id = Factory.create_release(db, home_shard)
          shard_id = Factory.create_shard(db, "bar")
          repo_foo = db.create_repo Repo.new(Repo::Ref.new("git", "foo"), nil, :canonical, synced_at: Time.utc)
          repo_bar = db.create_repo Repo.new(Repo::Ref.new("git", "bar"), shard_id, :canonical, synced_at: Time.utc)

          service = Service::SyncDependencies.new(db, release_id)

          spec_foo = JSON.parse(%({"git":"foo"}))
          service.add_dependency(Dependency.new("foo", spec_foo))
          spec_bar = JSON.parse(%({"git":"bar"}))
          service.update_dependency(Dependency.new("foo", spec_bar, :development))

          results = query_dependencies_with_repo(db)
          results.should eq [
            {"foo", spec_bar, "development", shard_id, "git", "bar", "canonical"},
          ]

          db.repos_pending_sync.should eq [] of Repo

          db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
            {"sync_dependencies:created", repo_foo, home_shard, {"name" => "foo", "scope" => "runtime", "release" => "0.1.0"}},
            {"sync_dependencies:updated", repo_bar, home_shard, {"name" => "foo", "scope" => "development", "release" => "0.1.0"}},
          ]
        end
      end
    end
  end

  it "#sync_dependencies" do
    transaction do |db|
      shard_id = Factory.create_shard(db)
      release_id = Factory.create_release(db, shard_id: shard_id)

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
      db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
        {"sync_dependencies:created", db.get_repo_id?("git", "run"), shard_id, {"name" => "run_dependency", "scope" => "runtime", "release" => "0.1.0"}},
        {"sync_dependencies:created", db.get_repo_id?("git", "dev"), shard_id, {"name" => "dev_dependency", "scope" => "development", "release" => "0.1.0"}},
        {"sync_dependencies:removed", db.get_repo_id?("git", "dev"), shard_id, {"name" => "dev_dependency", "scope" => "development", "release" => "0.1.0"}},
        {"sync_dependencies:created", db.get_repo_id?("git", "run2"), shard_id, {"name" => "run_dependency2", "scope" => "runtime", "release" => "0.1.0"}},
      ]
    end
  end
end
