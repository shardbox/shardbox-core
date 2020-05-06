require "spec"
require "../support/db"
require "../../src/service/create_owner"
require "../support/fetcher_mocks"

describe Service::CreateOwner do
  describe "#perform" do
    it "creates owner" do
      transaction do |db|
        repo_ref = Repo::Ref.new("github", "foo/bar")
        service = Service::CreateOwner.new(db, repo_ref)
        service.skip_owner_info = true

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

        service = Service::CreateOwner.new(db, repo_ref)
        service.skip_owner_info = true
        service.perform

        db.get_owner?(repo_ref).should eq Repo::Owner.new("github", "foo", shards_count: 1)
      end
    end

    it "picks up existing owner" do
      transaction do |db|
        repo_ref = Repo::Ref.new("github", "foo/bar")
        db.create_repo(Repo.new(repo_ref, shard_id: nil))
        db.create_owner(Repo::Owner.new("github", "foo"))
        db.get_owner?(repo_ref).should be_nil

        service = Service::CreateOwner.new(db, repo_ref)
        service.skip_owner_info = true
        service.perform

        db.get_owner?(repo_ref).should eq Repo::Owner.new("github", "foo", shards_count: 1)
      end
    end

    it "sets shards count" do
      transaction do |db|
        repo_ref = Repo::Ref.new("github", "foo/bar")
        db.create_repo(Repo.new(repo_ref, shard_id: nil))

        service = Service::CreateOwner.new(db, repo_ref)
        service.skip_owner_info = true
        service.perform

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

  describe ".fetch_owner_info_github" do
    it "do" do
      api = Shardbox::GitHubAPI.new("")
      api.mock_owner_info = Hash(String, JSON::Any).from_json(<<-JSON)
             {
               "bio": "verbum domini manet in eternum",
               "company": "RKK",
               "createdAt": "2020-05-03T16:50:55Z",
               "email": "boni@boni.org",
               "location": "Germany",
               "name": "Bonifatius",
               "websiteUrl": "boni.org"
             }
             JSON

      owner = Repo::Owner.new("github", "boni")

      Service::CreateOwner.fetch_owner_info_github(owner, api)

      owner.should eq Repo::Owner.new("github", "boni",
        name: "Bonifatius",
        description: "verbum domini manet in eternum",
        extra: {
          "location"    => JSON::Any.new("Germany"),
          "email"       => JSON::Any.new("boni@boni.org"),
          "website_url" => JSON::Any.new("boni.org"),
          "company"     => JSON::Any.new("RKK"),
          "created_at"  => JSON::Any.new("2020-05-03T16:50:55Z"),
        }
      )
    end
  end

  it "do" do
    api = Shardbox::GitHubAPI.new("")
    api.mock_owner_info = Hash(String, JSON::Any).from_json(<<-JSON)
           {
             "description": null,
             "name": null
           }
           JSON

    owner = Repo::Owner.new("github", "boni")

    Service::CreateOwner.fetch_owner_info_github(owner, api)

    owner.should eq Repo::Owner.new("github", "boni")
  end
end
