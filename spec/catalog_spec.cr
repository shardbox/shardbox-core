require "spec"
require "../src/catalog"

describe Catalog::Category do
  it ".from_yaml" do
    io = IO::Memory.new <<-YAML
      name: Foo
      description: Foo category
      shards:
      - github: foo/foo
      - git: https://example.com/foo.git
        description: Another foo
      - git: https://github.com/bar/foo.git
        description: Triple the foo
      YAML
    category = Catalog::Category.from_yaml(io)
    category.name.should eq "Foo"
    category.description.should eq "Foo category"
    category.shards.should eq [
      Catalog::Entry.new(Repo::Ref.new("github", "foo/foo")),
      Catalog::Entry.new(Repo::Ref.new("git", "https://example.com/foo.git"), "Another foo"),
      Catalog::Entry.new(Repo::Ref.new("github", "bar/foo"), "Triple the foo"),
    ]
  end
end
