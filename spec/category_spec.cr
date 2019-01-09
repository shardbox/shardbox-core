require "spec"
require "../src/category"

describe Category do
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
    category = Category.from_yaml(io)
    category.name.should eq "Foo"
    category.description.should eq "Foo category"
    category.shards.should eq [
      Category::Entry.new(Repo::Ref.new("github", "foo/foo")),
      Category::Entry.new(Repo::Ref.new("git", "https://example.com/foo.git"), "Another foo"),
      Category::Entry.new(Repo::Ref.new("github", "bar/foo"), "Triple the foo"),
    ]
  end
end
