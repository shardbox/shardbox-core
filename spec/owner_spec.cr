require "spec"
require "../src/repo/owner"

describe Repo::Owner do
  describe ".from_repo_ref" do
    it "returns nil for git" do
      Repo::Owner.from_repo_ref(Repo::Ref.new("git", "foo/bar")).should be_nil
    end

    it "creates owner for github" do
      Repo::Owner.from_repo_ref(Repo::Ref.new("github", "foo/bar")).should eq Repo::Owner.new("github", "foo")
    end

    it "creates owner for gitlab" do
      Repo::Owner.from_repo_ref(Repo::Ref.new("gitlab", "foo/bar")).should eq Repo::Owner.new("gitlab", "foo")
    end

    it "creates owner for bitbucket" do
      Repo::Owner.from_repo_ref(Repo::Ref.new("bitbucket", "foo/bar")).should eq Repo::Owner.new("bitbucket", "foo")
    end
  end
end
