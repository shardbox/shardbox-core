require "spec"
require "shards/logger"
require "shards/dependency"
# FIXME: shards/package is only a workaround, should be shards/resolvers/resolver
require "shards/package"
require "shards/resolvers/git"
require "../../../src/ext/shards/resolvers/git"
require "shards/spec/support/factories"
require "file_utils"

private def create_git_tag(project, version, message)
  Dir.cd(git_path(project)) do
    run "git tag -m '#{message}' #{version}"
  end
end

describe Shards::GitResolver do
  describe "#revision_info" do
    it "handles special characters" do
      create_git_repository("repo1")
      create_git_commit("repo1", "foo\nbar")
      create_git_tag("repo1", "v0.1", "bar\nfoo")
      create_git_commit("repo1", "foo\"bar")
      create_git_tag("repo1", "v0.2", "bar\"foo")
      resolver = Shards::GitResolver.find_resolver("git", "repo1", git_url("repo1")).as(Shards::GitResolver)

      revision_info = resolver.revision_info("0.1")
      revision_info.commit.message.should eq "foo\nbar"
      revision_info.tag.not_nil!.message.should eq "bar\nfoo"

      revision_info = resolver.revision_info("0.2")
      revision_info.commit.message.should eq "foo\"bar"
      revision_info.tag.not_nil!.message.should eq "bar\"foo"
    ensure
      FileUtils.rm_rf(git_path("repo1"))
    end

    it "resolves HEAD" do
      create_git_repository("repo2")
      create_git_commit("repo2", "foo bar")
      resolver = Shards::GitResolver.find_resolver("git", "repo2", git_url("repo2")).as(Shards::GitResolver)

      revision_info = resolver.revision_info("HEAD")
      revision_info.commit.message.should eq "foo bar"
      revision_info.tag.should be_nil
    ensure
      FileUtils.rm_rf(git_path("repo2"))
    end

    it "resolves symbolic reference" do
      create_git_repository("repo3")
      create_git_commit("repo3", "foo bar")
      create_git_tag("repo3", "v0.1", "bar foo")
      Dir.cd(git_path("repo3")) do
        run "git tag v0.2 v0.1"
      end
      resolver = Shards::GitResolver.find_resolver("git", "repo3", git_url("repo3")).as(Shards::GitResolver)

      revision_info = resolver.revision_info("0.2")
      revision_info.commit.message.should eq "foo bar"
      revision_info.tag.not_nil!.message.should eq "bar foo"
    ensure
      FileUtils.rm_rf(git_path("repo3"))
    end
  end
end
