require "spec"
require "../support/raven"
require "../../src/service/create_shard"
require "../support/db"

private def find_qualifier(url, name, &)
  result = {"~", nil}
  transaction do |db|
    if url.is_a?(String)
      repo_ref = Repo::Ref.parse(url)
    else
      repo_ref = url
    end
    repo_id = Factory.create_repo(db, repo_ref)
    repo = db.get_repo(repo_id)

    yield db

    result = Service::CreateShard.new(db, repo, name).find_qualifier
  end
  result
end

describe Service::CreateShard do
  describe "#find_qualifier" do
    context "with git resolver" do
      it "detects username/repo" do
        find_qualifier("mock://example.com/user/test.git", "test") { }.should eq({"", nil})
      end
    end

    it "detects username/repo" do
      find_qualifier("mock://example.com/user/test.git", "test") do |db|
        Factory.create_shard(db, "test")
      end.should eq({"user", nil})
    end

    it "users hostname" do
      find_qualifier("mock://example.com/user/sub/test.git", "test") do |db|
        Factory.create_shard(db, "test")
      end.should eq({"example.com", nil})
    end
  end

  it "with github resolver" do
    find_qualifier("github:testorg/test", "test") do |db|
      Factory.create_shard(db, "test")
    end.should eq({"testorg", nil})
  end

  it "with existing qualifier" do
    find_qualifier("mock://example.com/user/test.git", "test") do |db|
      Factory.create_shard(db, "test")
      Factory.create_shard(db, "test", qualifier: "example.com")
    end.should eq({"user", nil})
  end

  it "with different providers" do
    find_qualifier("github:testorg/test", "test") do |db|
      Factory.create_shard(db, "test")
      Factory.create_shard(db, "test", qualifier: "testorg")
    end.should eq({"github", nil})
  end

  it "with different providers" do
    find_qualifier("github:testorg/test", "test") do |db|
      Factory.create_shard(db, "test")
      Factory.create_shard(db, "test", qualifier: "testorg")
      Factory.create_shard(db, "test", qualifier: "github")
    end.should eq({"testorg-github", nil})
  end

  it "with archived shard" do
    shard_id = nil
    find_qualifier("github:testorg/test", "test") do |db|
      shard_id = Factory.create_shard(db, "test", archived_at: Time.utc)
    end.should eq({"", shard_id})

    find_qualifier("github:testorg/test", "test") do |db|
      shard_id = Factory.create_shard(db, "test", archived_at: Time.utc)
      Factory.create_shard(db, "test", qualifier: "testorg", archived_at: Time.utc)
    end.should eq({"", shard_id})

    find_qualifier("github:testorg/test", "test") do |db|
      Factory.create_shard(db, "test")
      shard_id = Factory.create_shard(db, "test", qualifier: "testorg", archived_at: Time.utc)
    end.should eq({"testorg", shard_id})
  end
end
