require "spec"
require "../support/db"
require "../support/jobs"
require "../support/mock_resolver"
require "../../src/service/import_shard"

private def persisted_shards(db)
  db.connection.query_all <<-SQL, as: {String, String?, String}
        SELECT
          name::text, description, qualifier::text
        FROM shards
        SQL
end

private def persisted_repos(db)
  db.connection.query_all <<-SQL, as: {String, String, String, String}
        SELECT
          resolver::text, url::text, role::text, shards.name::text
        FROM repos
        JOIN shards ON shards.id = repos.shard_id
        SQL
end

describe Service::ImportShard do
  mock_resolver = MockResolver.new
  mock_resolver.register("0.1.0", Factory.build_revision_info, <<-SPEC)
    name: test
    description: test shard
    version: 0.1.0
    SPEC

  it "fetches new shard" do
    repo_ref = Repo::Ref.new("git", "mock:test")
    service = Service::ImportShard.new(repo_ref)

    transaction do |db|
      shard_id = service.import_shard(db, Repo::Resolver.new(mock_resolver, repo_ref))

      persisted_shards(db).should eq [{"test", "test shard", ""}]
      persisted_repos(db).should eq [{"git", "mock:test", "canonical", "test"}]

      find_queued_tasks("Service::SyncRepo").map(&.arguments).should eq [%({"shard_id":#{shard_id}})]
    end
  end

  describe "duplicate name" do
    it "with git resolver" do
      repo_ref = Repo::Ref.new("git", "mock://example.com/git/test.git")
      service = Service::ImportShard.new(repo_ref)

      transaction do |db|
        Factory.create_shard(db, "test")

        shard_id = service.import_shard(db, Repo::Resolver.new(mock_resolver, repo_ref))

        persisted_shards(db).should eq [{"test", nil, ""}, {"test", "test shard", "example.com"}]
        persisted_repos(db).should eq [{"git", "mock://example.com/git/test.git", "canonical", "test"}]

        find_queued_tasks("Service::SyncRepo").map(&.arguments).should eq [%({"shard_id":#{shard_id}})]
      end
    end

    it "with github resolver" do
      repo_ref = Repo::Ref.new("github", "testorg/test")
      service = Service::ImportShard.new(repo_ref)

      transaction do |db|
        Factory.create_shard(db, "test")

        shard_id = service.import_shard(db, Repo::Resolver.new(mock_resolver, repo_ref))

        persisted_shards(db).should eq [{"test", nil, ""}, {"test", "test shard", "testorg"}]
        persisted_repos(db).should eq [{"github", "testorg/test", "canonical", "test"}]

        find_queued_tasks("Service::SyncRepo").map(&.arguments).should eq [%({"shard_id":#{shard_id}})]
      end
    end

    it "with existing qualifier" do
      repo_ref = Repo::Ref.new("git", "mock://example.com/git/test.git")
      service = Service::ImportShard.new(repo_ref)

      transaction do |db|
        Factory.create_shard(db, "test")
        Factory.create_shard(db, "test", qualifier: "example.com")

        shard_id = service.import_shard(db, Repo::Resolver.new(mock_resolver, repo_ref))

        persisted_shards(db).should eq [{"test", nil, ""}, {"test", nil, "example.com"}, {"test", "test shard", "example.com-git"}]
        persisted_repos(db).should eq [{"git", "mock://example.com/git/test.git", "canonical", "test"}]

        find_queued_tasks("Service::SyncRepo").map(&.arguments).should eq [%({"shard_id":#{shard_id}})]
      end
    end
  end

  it "skips existing repo" do
    repo_ref = Repo::Ref.new("git", "mock://example.com/git/test.git")

    service = Service::ImportShard.new(repo_ref)

    transaction do |db|
      shard_id = Factory.create_shard(db, "test")
      Factory.create_repo(db, shard_id, repo_ref)

      shard_id = service.import_shard(db, Repo::Resolver.new(mock_resolver, repo_ref))

      persisted_shards(db).should eq [{"test", nil, ""}]
      persisted_repos(db).should eq [{"git", "mock://example.com/git/test.git", "canonical", "test"}]

      find_queued_tasks("Service::SyncRepo").map(&.arguments).should be_empty
    end
  end
end
