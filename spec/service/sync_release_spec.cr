require "spec"
require "../../src/service/sync_release"
require "../../src/repo"
require "../../src/repo/resolver"
require "../support/db"
require "../support/mock_resolver"
require "../support/raven"

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

      service = Service::SyncRelease.new(db, shard_id, "0.1.0")

      service.sync_release(Repo::Resolver.new(mock_resolver, Repo::Ref.new("git", "foo")))

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
      row[5].should eq 0
      row[6].should eq nil
      row[7].should eq nil

      db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
        {"sync_release:created", nil, shard_id, {"version" => "0.1.0"}},
      ]
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

      service = Service::SyncRelease.new(db, shard_id, "0.1.0")

      service.sync_release(Repo::Resolver.new(mock_resolver, Repo::Ref.new("git", "foo")))

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

      db.last_activities.should eq [] of LogActivity
    end
  end

  it "handles missing spec" do
    commit_1 = Factory.build_commit("12345678")
    revision_info_1 = Release::RevisionInfo.new Factory.build_tag("v0.1.0"), commit_1
    mock_resolver = MockResolver.new
    mock_resolver.register("0.1.0", revision_info_1, nil)

    transaction do |db|
      shard_id = Factory.create_shard(db)
      service = Service::SyncRelease.new(db, shard_id, "0.1.0")
      resolver = Repo::Resolver.new(mock_resolver, Repo::Ref.new("git", "foo"))

      service.sync_release(resolver)

      results = db.connection.query_all <<-SQL, as: {Int64, Int64, String, Time, JSON::Any, JSON::Any, Int32?, Bool?, Time?}
        SELECT
          id, shard_id, version, released_at, spec, revision_info, position, latest, yanked_at
        FROM
          releases
        SQL

      results.size.should eq 1

      release_id, result_shard_id, version, released_at, spec, revision_info, position, latest, yanked_at = results.first
      result_shard_id.should eq shard_id
      version.should eq "0.1.0"
      released_at.should eq commit_1.time
      spec.should eq JSON.parse(%({}))
      revision_info.should eq JSON.parse(revision_info_1.to_json)
      position.should eq 0
      latest.should be_nil
      yanked_at.should be_nil

      results = db.connection.query_one(<<-SQL, release_id, as: {Int64}).should eq 0
        SELECT
          COUNT(*)
        FROM
          dependencies
        WHERE
          release_id = $1
        SQL

      db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
        {"sync_release:created", nil, shard_id, {"version" => "0.1.0"}},
      ]
    end
  end

  describe "#sync_files" do
    it "stores README" do
      commit_1 = Factory.build_commit("12345678")
      revision_info_1 = Release::RevisionInfo.new Factory.build_tag("v0.1.0"), commit_1
      mock_resolver = MockResolver.new
      version = mock_resolver.register("0.1.0", revision_info_1, <<-SPEC)
            name: foo
            version: 0.1.0
            SPEC
      transaction do |db|
        shard_id = Factory.create_shard(db)
        release_id = Factory.create_release(db, shard_id, "0.1.0")

        service = Service::SyncRelease.new(db, shard_id, "0.1.0")

        version.files["README.md"] = "Hello World!"
        service.sync_files(release_id, Repo::Resolver.new(mock_resolver, Repo::Ref.new("git", "foo")))
        db.fetch_file(release_id, "README.md").should eq "Hello World!"

        version.files["README.md"] = "Hello Foo!"
        service.sync_files(release_id, Repo::Resolver.new(mock_resolver, Repo::Ref.new("git", "foo")))
        db.fetch_file(release_id, "README.md").should eq "Hello Foo!"

        version.files.delete("README.md")
        service.sync_files(release_id, Repo::Resolver.new(mock_resolver, Repo::Ref.new("git", "foo")))
        db.fetch_file(release_id, "README.md").should be_nil

        version.files["Readme.md"] = "Hello Camel!"
        service.sync_files(release_id, Repo::Resolver.new(mock_resolver, Repo::Ref.new("git", "foo")))
        db.fetch_file(release_id, "README.md").should eq "Hello Camel!"

        version.files["README.md"] = "Hello YELL!"
        service.sync_files(release_id, Repo::Resolver.new(mock_resolver, Repo::Ref.new("git", "foo")))
        db.fetch_file(release_id, "README.md").should eq "Hello YELL!"
      end
    end
  end
end
