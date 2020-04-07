require "spec"
require "shards/logger"
require "shards/dependency"
require "shards/resolvers/resolver"
require "shards/resolvers/git"
require "../../../src/ext/shards/resolvers/git"
require "shards/spec/support/factories"
require "file_utils"

struct ShardsHelper
  def resolver(name, config = {} of String => String)
    config = config.merge({"git" => git_url(name)})
    dependency = Shards::Dependency.new(name, config)
    Shards::GitResolver.new(dependency)
  end
end

class Shards::Dependency
  def self.new(name, config)
    previous_def
  end
end

private def create_git_tag(project, version, message)
  Dir.cd(git_path(project)) do
    run "git tag -m '#{message}' #{version}"
  end
end

describe Shards::GitResolver do
  describe "#revision_info" do
    it "handles special characters" do
      helper = ShardsHelper.new
      create_git_repository("foo")
      create_git_commit("foo", "foo\nbar")
      create_git_tag("foo", "v0.1", "bar\nfoo")
      create_git_commit("foo", "foo\"bar")
      create_git_tag("foo", "v0.2", "bar\"foo")
      resolver = helper.resolver("foo")

      revision_info = resolver.revision_info("0.1")
      revision_info.commit.message.should eq "foo\nbar\n"
      revision_info.tag.not_nil!.message.should eq "bar\nfoo\n"

      revision_info = resolver.revision_info("0.2")
      revision_info.commit.message.should eq "foo\"bar\n"
      revision_info.tag.not_nil!.message.should eq "bar\"foo\n"
    ensure
      if helper
        FileUtils.rm_rf(git_path("foo"))
      end
    end

    it "resolves HEAD" do
      helper = ShardsHelper.new
      create_git_repository("foo")
      create_git_commit("foo", "foo bar")
      resolver = helper.resolver("foo")

      revision_info = resolver.revision_info("HEAD")
      revision_info.commit.message.should eq "foo bar\n"
      revision_info.tag.should be_nil
    ensure
      if helper
        FileUtils.rm_rf(git_path("foo"))
      end
    end

    it "resolves symbolic reference" do
      helper = ShardsHelper.new
      create_git_repository("foo")
      create_git_commit("foo", "foo bar")
      create_git_tag("foo", "v0.1", "bar foo")
      Dir.cd(git_path("foo")) do
        run "git tag v0.2 v0.1"
      end
      resolver = helper.resolver("foo")

      revision_info = resolver.revision_info("0.2")
      revision_info.commit.message.should eq "foo bar\n"
      revision_info.tag.not_nil!.message.should eq "bar foo\n"
    ensure
      if helper
        FileUtils.rm_rf(git_path("foo"))
      end
    end
  end
end
