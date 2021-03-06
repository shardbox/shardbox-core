require "spec"
require "../src/repo"

describe Repo::Ref do
  describe ".new" do
    describe "with URI" do
      it "defaults to git resolver" do
        repo_ref = Repo::Ref.new("file:///repo.git")
        repo_ref.resolver.should eq "git"
        repo_ref.url.should eq "file:///repo.git"
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

      it "raises for invalid git URL" do
        expect_raises(Exception, %(Invalid url for resolver git: "http://example.com")) do
          Repo::Ref.new("http://example.com")
        end
      end
    end
  end

  it "#name" do
    Repo::Ref.new("file:///repo.git").name.should eq "repo"
    Repo::Ref.new("file:///repo").name.should eq "repo"
    Repo::Ref.new("https://example.com/foo/bar.git").name.should eq "bar"
    Repo::Ref.new("https://example.com/foo/bar.git/").name.should eq "bar"
    Repo::Ref.new("https://example.com/foo/bar/").name.should eq "bar"
    Repo::Ref.new("github", "foo/bar").name.should eq "bar"
  end

  it "#to_uri" do
    Repo::Ref.new("file:///repo.git").to_uri.should eq URI.parse("file:///repo.git")
    Repo::Ref.new("file:///repo").to_uri.should eq URI.parse("file:///repo")
    Repo::Ref.new("https://example.com/foo/bar.git").to_uri.should eq URI.parse("https://example.com/foo/bar.git")
    Repo::Ref.new("https://example.com/foo/bar.git/").to_uri.should eq URI.parse("https://example.com/foo/bar.git/")
    Repo::Ref.new("github", "foo/bar").to_uri.should eq URI.parse("https://github.com/foo/bar")
  end

  it "#base_url_source" do
    Repo::Ref.new("github", "foo/bar").base_url_source.should eq URI.parse("https://github.com/foo/bar/tree/master/")
    Repo::Ref.new("github", "foo/bar").base_url_source("HEAD").should eq URI.parse("https://github.com/foo/bar/tree/master/")
    Repo::Ref.new("github", "foo/bar").base_url_source("12345").should eq URI.parse("https://github.com/foo/bar/tree/12345/")

    Repo::Ref.new("gitlab", "foo/bar").base_url_source.should eq URI.parse("https://gitlab.com/foo/bar/-/tree/master/")
    Repo::Ref.new("gitlab", "foo/bar").base_url_source("HEAD").should eq URI.parse("https://gitlab.com/foo/bar/-/tree/master/")
    Repo::Ref.new("gitlab", "foo/bar").base_url_source("12345").should eq URI.parse("https://gitlab.com/foo/bar/-/tree/12345/")

    Repo::Ref.new("bitbucket", "foo/bar").base_url_source.should eq URI.parse("https://bitbucket.com/foo/bar/src/master/")
    Repo::Ref.new("bitbucket", "foo/bar").base_url_source("HEAD").should eq URI.parse("https://bitbucket.com/foo/bar/src/master/")
    Repo::Ref.new("bitbucket", "foo/bar").base_url_source("12345").should eq URI.parse("https://bitbucket.com/foo/bar/src/12345/")

    Repo::Ref.new("git", "foo/bar").base_url_source.should be_nil
    Repo::Ref.new("git", "foo/bar").base_url_source("12345").should be_nil
  end

  it "#base_url_raw" do
    Repo::Ref.new("github", "foo/bar").base_url_raw.should eq URI.parse("https://github.com/foo/bar/raw/master/")
    Repo::Ref.new("github", "foo/bar").base_url_raw("HEAD").should eq URI.parse("https://github.com/foo/bar/raw/master/")
    Repo::Ref.new("github", "foo/bar").base_url_raw("12345").should eq URI.parse("https://github.com/foo/bar/raw/12345/")

    Repo::Ref.new("gitlab", "foo/bar").base_url_raw.should eq URI.parse("https://gitlab.com/foo/bar/-/raw/master/")
    Repo::Ref.new("gitlab", "foo/bar").base_url_raw("HEAD").should eq URI.parse("https://gitlab.com/foo/bar/-/raw/master/")
    Repo::Ref.new("gitlab", "foo/bar").base_url_raw("12345").should eq URI.parse("https://gitlab.com/foo/bar/-/raw/12345/")

    Repo::Ref.new("bitbucket", "foo/bar").base_url_raw.should eq URI.parse("https://bitbucket.com/foo/bar/raw/master/")
    Repo::Ref.new("bitbucket", "foo/bar").base_url_raw("HEAD").should eq URI.parse("https://bitbucket.com/foo/bar/raw/master/")
    Repo::Ref.new("bitbucket", "foo/bar").base_url_raw("12345").should eq URI.parse("https://bitbucket.com/foo/bar/raw/12345/")

    Repo::Ref.new("git", "foo/bar").base_url_raw.should be_nil
    Repo::Ref.new("git", "foo/bar").base_url_raw("12345").should be_nil
  end

  it "#nice_url" do
    Repo::Ref.new("file:///repo.git").nice_url.should eq "file:///repo.git"
    Repo::Ref.new("file:///repo").nice_url.should eq "file:///repo"
    Repo::Ref.new("https://example.com/foo/bar").nice_url.should eq "example.com/foo/bar"
    Repo::Ref.new("https://example.com/foo/bar.git/").nice_url.should eq "example.com/foo/bar"
    Repo::Ref.new("github", "foo/bar").nice_url.should eq "foo/bar"
    Repo::Ref.new("gitlab", "foo/bar").nice_url.should eq "foo/bar"
    Repo::Ref.new("bitbucket", "foo/bar").nice_url.should eq "foo/bar"
  end

  it "#slug" do
    Repo::Ref.new("file:///repo.git").slug.should eq "file:///repo.git"
    Repo::Ref.new("file:///repo").slug.should eq "file:///repo"
    Repo::Ref.new("https://example.com/foo/bar").slug.should eq "example.com/foo/bar"
    Repo::Ref.new("https://example.com/foo/bar.git/").slug.should eq "example.com/foo/bar"
    Repo::Ref.new("github", "foo/bar").slug.should eq "github.com/foo/bar"
    Repo::Ref.new("gitlab", "foo/bar").slug.should eq "gitlab.com/foo/bar"
    Repo::Ref.new("bitbucket", "foo/bar").slug.should eq "bitbucket.com/foo/bar"
  end

  it "#<=>" do
    Repo::Ref.new("git", "bar").should be < Repo::Ref.new("git", "baz")
    (Repo::Ref.new("git", "bar") <=> Repo::Ref.new("git", "bar")).should eq 0
    Repo::Ref.new("git", "bar").should be > Repo::Ref.new("git", "Bar")
    (Repo::Ref.new("github", "goo/bar") <=> Repo::Ref.new("github", "goo/bar")).should eq 0
    (Repo::Ref.new("github", "goo/bar") <=> Repo::Ref.new("github", "goo/Bar")).should eq 0
    (Repo::Ref.new("github", "goo/bar") <=> Repo::Ref.new("github", "Goo/bar")).should eq 0
    Repo::Ref.new("github", "goo/bar").should be < Repo::Ref.new("github", "foo/baz")
    Repo::Ref.new("github", "goo/Bar").should be < Repo::Ref.new("github", "foo/baz")
    Repo::Ref.new("github", "goo/bar").should be < Repo::Ref.new("github", "foo/Baz")
    Repo::Ref.new("github", "goo/bar").should be < Repo::Ref.new("gitlab", "foo/baz")
    Repo::Ref.new("github", "goo/bar").should be < Repo::Ref.new("bitbucket", "foo/baz")
    Repo::Ref.new("github", "goo/bar").should be > Repo::Ref.new("bitbucket", "foo/bar")
    Repo::Ref.new("github", "goo/bar").should be > Repo::Ref.new("bitbucket", "goo/bar")

    Repo::Ref.new("git", "https://foo/bar").should be < Repo::Ref.new("github", "foo/bar")
  end
end
