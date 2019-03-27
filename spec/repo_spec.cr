require "spec"
require "../src/repo"

describe Repo::Ref do
  describe ".new" do
    describe "with URI" do
      it "defaults to git resolver" do
        repo_ref = Repo::Ref.new("file:repo.git")
        repo_ref.resolver.should eq "git"
        repo_ref.url.should eq "file:repo.git"
      end

      it "identifies service providers" do
        {"github", "gitlab", "bitbucket"}.each do |provider|
          Repo::Ref.new("https://#{provider}.com/foo/foo").should eq Repo::Ref.new(provider, "foo/foo")
          Repo::Ref.new("https://#{provider}.com/foo/foo.git").should eq Repo::Ref.new(provider, "foo/foo")
          Repo::Ref.new("https://#{provider}.com/foo/foo/").should eq Repo::Ref.new(provider, "foo/foo")
          Repo::Ref.new("https://#{provider}.com/foo/foo.git/").should eq Repo::Ref.new(provider, "foo/foo")
          Repo::Ref.new("https://www.#{provider}.com/foo/foo").should eq Repo::Ref.new(provider, "foo/foo")
        end
      end
    end
  end

  it "#name" do
    Repo::Ref.new("file:repo.git").name.should eq "repo"
    Repo::Ref.new("file:repo").name.should eq "repo"
    Repo::Ref.new("https://example.com/foo/bar.git").name.should eq "bar"
    Repo::Ref.new("https://example.com/foo/bar.git/").name.should eq "bar"
    Repo::Ref.new("https://example.com/foo/bar/").name.should eq "bar"
    Repo::Ref.new("github", "foo/bar").name.should eq "bar"
  end

  it "#to_uri" do
    Repo::Ref.new("file:repo.git").to_uri.should eq URI.parse("file:repo.git")
    Repo::Ref.new("file:repo").to_uri.should eq URI.parse("file:repo")
    Repo::Ref.new("https://example.com/foo/bar.git").to_uri.should eq URI.parse("https://example.com/foo/bar.git")
    Repo::Ref.new("https://example.com/foo/bar.git/").to_uri.should eq URI.parse("https://example.com/foo/bar.git/")
    Repo::Ref.new("github", "foo/bar").to_uri.should eq URI.parse("https://github.com/foo/bar")
  end
end
