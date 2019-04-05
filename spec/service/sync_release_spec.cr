require "spec"
require "../../src/service/sync_release"
require "../support/db"
require "../../src/repo"
require "../../src/repo/resolver"
require "../support/mock_resolver"

describe Service::SyncRelease do
  commit_1 = Factory.build_commit("12345678")
  revision_info_1 = Release::RevisionInfo.new Factory.build_tag("v0.1.0"), commit_1
  mock_resolver = MockResolver.new
  mock_resolver.register("0.1.0", revision_info_1, <<-SPEC)
        name: foo
        version: 0.1.0
        SPEC

  it "stores new release" do
    transaction do |db|
      shard_id = Factory.create_shard(db)
      # repo_id = Factory.create_repo(db, shard_id: shard_id)

      service = Service::SyncRelease.new(shard_id, "0.1.0")

      service.sync_release(db, Repo::Resolver.new(mock_resolver, Repo::Ref.new("git", "foo")))

      results = db.connection.query_all <<-SQL, as: {Int64, String, Time, JSON::Any, JSON::Any, Int64?, Bool?, Time?}
        SELECT
          shard_id, version, released_at, spec, revision_info, position, latest, yanked_at
        FROM releases
        SQL

      results.size.should eq 1
      row = results.first
      row[0].should eq shard_id
      row[1].should eq "0.1.0"
      row[2].should eq commit_1.time
      row[3].should eq JSON.parse(%({"name":"foo","version":"0.1.0"}))
      row[4].should eq JSON.parse(revision_info_1.to_json)
      row[5].should eq nil
      row[6].should eq nil
      row[7].should eq nil
    end
  end

  it "updates existing release" do
    transaction do |db|
      shard_id = Factory.create_shard(db)
      # repo_id = Factory.create_repo(db, shard_id: shard_id)
      db.connection.exec <<-SQL, shard_id
        INSERT INTO releases (shard_id, version, released_at, spec, revision_info, position, latest, yanked_at)
        VALUES($1, '0.1.0', '2018-12-30 00:00:00 UTC', '{}', '{}', 1, true, NOW())
        SQL

      service = Service::SyncRelease.new(shard_id, "0.1.0")

      service.sync_release(db, Repo::Resolver.new(mock_resolver, Repo::Ref.new("git", "foo")))

      results = db.connection.query_all <<-SQL, as: {Int64, String, Time, JSON::Any, JSON::Any, Int32?, Bool?, Time?}
        SELECT
          shard_id, version, released_at, spec, revision_info, position, latest, yanked_at
        FROM releases
        SQL

      results.size.should eq 1
      row = results.first
      row[0].should eq shard_id
      row[1].should eq "0.1.0"
      row[2].should eq commit_1.time
      row[3].should eq JSON.parse(%({"name":"foo","version":"0.1.0"}))
      row[4].should eq JSON.parse(revision_info_1.to_json)
      row[5].should eq 1
      row[6].should eq true
      row[7].should eq nil
    end
  end

  it "#sync_dependencies" do
    transaction do |db|
      shard_id = Factory.create_shard(db)
      release_id = Factory.create_release(db, shard_id: shard_id)

      service = Service::SyncRelease.new(shard_id, "0.0.0")

      run_spec = JSON.parse(%({"mock":"run"}))
      dev_spec = JSON.parse(%({"mock":"dev"}))
      dependencies = [
        Dependency.new("run_dependency", run_spec),
        Dependency.new("dev_dependency", dev_spec, :development),
      ]

      service.sync_dependencies(db, release_id, dependencies)

      results = db.connection.query_all <<-SQL, as: {Int64?, String, JSON::Any, String}
        SELECT
          shard_id, name::text, spec, scope::text
        FROM dependencies
        SQL

      results.should eq [
        {nil, "run_dependency", run_spec, "runtime"},
        {nil, "dev_dependency", dev_spec, "development"},
      ]

      run_spec2 = JSON.parse(%({"mock":"run2"}))
      new_dependencies = [
        Dependency.new("run_dependency", run_spec),
        Dependency.new("run_dependency2", run_spec2),
      ]

      service.sync_dependencies(db, release_id, new_dependencies)

      results = db.connection.query_all <<-SQL, as: {Int64?, String, JSON::Any, String}
        SELECT
          shard_id, name::text, spec, scope::text
        FROM dependencies
        SQL

      results.should eq [
        {nil, "run_dependency", run_spec, "runtime"},
        {nil, "run_dependency2", run_spec2, "runtime"},
      ]
    end
  end

  it "handles missing spec" do
    commit_1 = Factory.build_commit("12345678")
    revision_info_1 = Release::RevisionInfo.new Factory.build_tag("v0.1.0"), commit_1
    mock_resolver = MockResolver.new
    mock_resolver.register("0.1.0", revision_info_1, nil)

    transaction do |db|
      shard_id = Factory.create_shard(db)
      service = Service::SyncRelease.new(shard_id, "0.1.0")
      resolver = Repo::Resolver.new(mock_resolver, Repo::Ref.new("git", "foo"))

      service.sync_release(db, resolver)

      results = db.connection.query_all <<-SQL, as: {Int64, String, Time, JSON::Any, JSON::Any, Int64?, Bool?, Time?}
        SELECT
          shard_id, version, released_at, spec, revision_info, position, latest, yanked_at
        FROM releases
        SQL

      results.size.should eq 1
      row = results.first
      row[0].should eq shard_id
      row[1].should eq "0.1.0"
      row[2].should eq commit_1.time
      row[3].should eq JSON.parse(%({}))
      row[4].should eq JSON.parse(revision_info_1.to_json)
      row[5].should eq nil
      row[6].should eq nil
      row[7].should eq nil
    end
  end
end
