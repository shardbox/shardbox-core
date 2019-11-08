require "spec"
require "../src/catalog"
require "file_utils"

private def with_tempdir(name)
  path = File.join(Dir.tempdir, name)
  FileUtils.mkdir_p(path)

  begin
    yield path
  ensure
    FileUtils.rm_r(path) if File.exists?(path)
  end
end

describe Catalog do
  describe ".read" do
    it "reads" do
      with_tempdir("catalog-mirrors") do |catalog_path|
        File.write(File.join(catalog_path, "category.yml"), <<-YAML)
          name: Category
          shards:
          - git: foo/foo
            mirrors:
            - git: bar/foo
            - git: baz/foo
              role: legacy
            - git: qux/foo
              role: legacy
          - git: bar/bar
            mirrors:
            - git: foo/bar
              role: legacy
          YAML
        categories, entries = Catalog.read(catalog_path)
        categories.keys.should eq ["category"]
      end
    end

    describe "duplicate mirrors" do
      it "same entry" do
        with_tempdir("catalog-mirrors") do |catalog_path|
          File.write(File.join(catalog_path, "category.yml"), <<-YAML)
            name: Category
            shards:
            - git: foo/foo
              mirrors:
              - git: foo/foo
            YAML
          expect_raises(Catalog::Error, "duplicate mirror git:foo/foo") do
            Catalog.read(catalog_path)
          end
        end
      end

      it "both mirrors" do
        with_tempdir("catalog-mirrors") do |catalog_path|
          File.write(File.join(catalog_path, "category.yml"), <<-YAML)
            name: Category
            shards:
            - git: foo/foo
              mirrors:
              - git: foo/bar
            - git: foo/baz
              mirrors:
              - git: foo/bar
            YAML
          expect_raises(Catalog::Error, "duplicate mirror git:foo/bar") do
            Catalog.read(catalog_path)
          end
        end
      end

      it "mirror and canonical" do
        with_tempdir("catalog-mirrors") do |catalog_path|
          File.write(File.join(catalog_path, "category.yml"), <<-YAML)
            name: Category
            shards:
            - git: foo/foo
              mirrors:
              - git: foo/bar
            - git: foo/bar
            YAML
          expect_raises(Catalog::Error, "duplicate mirror git:foo/bar") do
            Catalog.read(catalog_path)
          end
        end
      end
    end
  end
end

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
