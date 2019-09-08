require "spec"
require "../src/dependency"

describe Dependency do
  it "#version_reference" do
    Dependency.new("foo", JSON.parse(%({"version": "1.0"}))).version_reference.should eq({"version", "1.0"})
    Dependency.new("foo", JSON.parse(%({"branch": "master"}))).version_reference.should eq({"branch", "master"})
    Dependency.new("foo", JSON.parse(%({"commit": "0123456789abcdef"}))).version_reference.should eq({"commit", "0123456789abcdef"})
    Dependency.new("foo", JSON.parse(%({"tag": "foo"}))).version_reference.should eq({"tag", "foo"})
    Dependency.new("foo", JSON.parse(%({}))).version_reference.should be_nil

    Dependency.new("foo", JSON.parse(%({"commit": "0123456789abcdef", "tag": "foo"}))).version_reference.should eq({"commit", "0123456789abcdef"})
    Dependency.new("foo", JSON.parse(%({"tag": "foo", "version": "1.0"}))).version_reference.should eq({"tag", "foo"})
    Dependency.new("foo", JSON.parse(%({"version": "1.0", "branch": "master"}))).version_reference.should eq({"version", "1.0"})
  end

  it "#repo_ref" do
    Dependency.new("foo", JSON.parse(%({"git": "http://example.com/foo.git"}))).repo_ref.should eq Repo::Ref.new("git", "http://example.com/foo.git")
    Dependency.new("foo", JSON.parse(%({"github": "foo/foo"}))).repo_ref.should eq Repo::Ref.new("github", "foo/foo")
  end
end
