require "spec"
require "shards/logger"
require "shards/dependency"
require "shards/resolvers/resolver"
require "shards/resolvers/git"
require "../../../src/ext/shards/resolvers/git"
require "../../../lib/shards/test/support/factories"
require "file_utils"

struct ShardsHelper
  include Shards::Factories

  def resolver(name, config = {} of String => String)
    config = config.merge({"git" => git_url(name)})
    dependency = Shards::Dependency.new(name, config)
    Shards::GitResolver.new(dependency)
  end

  def create_git_tag(project, version, message)
    Dir.cd(git_path(project)) do
      run "git tag -m '#{message}' #{version}"
    end
  end
end

describe Shards::GitResolver do
  describe "#revision_info" do
    it "handles special characters" do
      helper = ShardsHelper.new
      helper.create_git_repository("foo-revision_info")
      helper.create_git_commit("foo-revision_info", "foo\nbar")
      helper.create_git_tag("foo-revision_info", "v0.1", "bar\nfoo")
      helper.create_git_commit("foo-revision_info", "foo\"bar")
      helper.create_git_tag("foo-revision_info", "v0.2", "bar\"foo")

      resolver = helper.resolver("foo-revision_info")

      revision_info = resolver.revision_info("0.1")
      revision_info.commit.message.should eq "foo\nbar\n"
      revision_info.tag.not_nil!.message.should eq "bar\nfoo\n"

      revision_info = resolver.revision_info("0.2")
      revision_info.commit.message.should eq "foo\"bar\n"
      revision_info.tag.not_nil!.message.should eq "bar\"foo\n"
    ensure
      if helper
        FileUtils.rm_rf(helper.git_path("foo-revision_info"))
      end
    end
  end
end
