require "spec"
require "../support/raven"
require "../../src/service/create_shard"
require "../support/db"

describe Service::ImportShard do
  describe "duplicate name" do
    context "with git resolver" do
      it "detects username/repo" do
        transaction do |db|
          repo_id = Factory.create_repo(db, Repo::Ref.new("git", "mock://example.com/user/test.git"))
          repo = db.get_repo(repo_id)

          Factory.create_shard(db, "test")

          Service::CreateShard.new(db, repo, "test").perform

          ShardsDBHelper.persisted_shards(db).should eq [{"test", "", nil}, {"test", "user", nil}]
        end
      end

      it "users hostname" do
        transaction do |db|
          repo_id = Factory.create_repo(db, Repo::Ref.new("git", "mock://example.com/user/sub/test.git"))
          repo = db.get_repo(repo_id)

          Factory.create_shard(db, "test")

          Service::CreateShard.new(db, repo, "test").perform

          ShardsDBHelper.persisted_shards(db).should eq [{"test", "", nil}, {"test", "example.com", nil}]
        end
      end
    end

    it "with github resolver" do
      transaction do |db|
        repo_id = Factory.create_repo(db, Repo::Ref.new("github", "testorg/test"))
        repo = db.get_repo(repo_id)

        Factory.create_shard(db, "test")

        Service::CreateShard.new(db, repo, "test").perform

        ShardsDBHelper.persisted_shards(db).should eq [{"test", "", nil}, {"test", "testorg", nil}]
      end
    end

    it "with existing qualifier" do
      transaction do |db|
        repo_id = Factory.create_repo(db, Repo::Ref.new("git", "mock://example.com/user/test.git"))
        repo = db.get_repo(repo_id)

        Factory.create_shard(db, "test")
        Factory.create_shard(db, "test", qualifier: "example.com")

        Service::CreateShard.new(db, repo, "test").perform

        ShardsDBHelper.persisted_shards(db).should eq [{"test", "", nil}, {"test", "example.com", nil}, {"test", "user", nil}]
      end
    end
  end
end
