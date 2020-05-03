require "spec"
require "../support/db"
require "../../src/service/create_owner"

describe Service::CreateOwner do
  describe "#perform" do
    it "creates owner" do
      transaction do |db|
        repo_ref = Repo::Ref.new("github", "foo/bar")
        service = Service::CreateOwner.new(db, repo_ref)
        db.get_owner?("github", "foo").should be_nil
        db.get_owner?(repo_ref).should be_nil
        service.perform
        db.get_owner?("github", "foo").should eq Repo::Owner.new("github", "foo", shards_count: 0)
        db.get_owner?(repo_ref).should be_nil
      end
    end

    it "assigns owner to repo" do
      transaction do |db|
        repo_ref = Repo::Ref.new("github", "foo/bar")
        db.create_repo(Repo.new(repo_ref, shard_id: nil))
        db.get_owner?(repo_ref).should be_nil

        Service::CreateOwner.new(db, repo_ref).perform

        db.get_owner?(repo_ref).should eq Repo::Owner.new("github", "foo", shards_count: 1)
      end
    end

    it "picks up existing owner" do
      transaction do |db|
        repo_ref = Repo::Ref.new("github", "foo/bar")
        db.create_repo(Repo.new(repo_ref, shard_id: nil))
        db.create_owner(Repo::Owner.new("github", "foo"))
        db.get_owner?(repo_ref).should be_nil

        Service::CreateOwner.new(db, repo_ref).perform

        db.get_owner?(repo_ref).should eq Repo::Owner.new("github", "foo", shards_count: 1)
      end
    end

    it "sets shards count" do
      transaction do |db|
        repo_ref = Repo::Ref.new("github", "foo/bar")
        db.create_repo(Repo.new(repo_ref, shard_id: nil))
        Service::CreateOwner.new(db, repo_ref).perform

        db.get_owner?(repo_ref).should eq Repo::Owner.new("github", "foo", shards_count: 1)

        repo_ref_baz = Repo::Ref.new("github", "foo/baz")
        db.create_repo(Repo.new(repo_ref_baz, shard_id: nil))
        owner = Service::CreateOwner.new(db, repo_ref_baz).perform
        owner = owner.not_nil!

        db.get_owned_repos(owner.id).map(&.ref).should eq [repo_ref, repo_ref_baz]
        db.get_owner?(repo_ref).should eq Repo::Owner.new("github", "foo", shards_count: 2)
      end
    end
  end
end
