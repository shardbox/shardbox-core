require "spec"
require "../../src/catalog"
require "file_utils"

private def with_tempdir(name, &)
  path = File.join(Dir.tempdir, name)
  FileUtils.mkdir_p(path)

  begin
    yield path
  ensure
    FileUtils.rm_r(path) if File.exists?(path)
  end
end

describe "duplicate repos" do
  it "same entry" do
    with_tempdir("catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/foo
          mirrors:
          - git: foo/foo
        YAML
      expect_raises(Catalog::Error, "category: duplicate mirror git:foo/foo also in category") do
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
      expect_raises(Catalog::Error, "category: duplicate mirror git:foo/bar also on git:foo/foo in category") do
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
      expect_raises(Catalog::Error, "category: duplicate repo git:foo/bar also on git:foo/foo in category") do
        Catalog.read(catalog_path)
      end
    end
  end

  it "canonical and mirror" do
    with_tempdir("catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/bar
        - git: foo/foo
          mirrors:
          - git: foo/bar
        YAML
      expect_raises(Catalog::Error, "category: duplicate mirror git:foo/bar also in category") do
        Catalog.read(catalog_path)
      end
    end
  end

  it "canonical with different descriptions" do
    with_tempdir("catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/bar
          description: A
        - git: foo/bar
          description: B
        YAML
      expect_raises(Catalog::Error, "category: duplicate repo git:foo/bar also in category") do
        Catalog.read(catalog_path)
      end
    end
  end

  it "canonical with same descriptions" do
    with_tempdir("catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/bar
          description: A
        - git: foo/bar
          description: A
        YAML
      expect_raises(Catalog::Error, "category: duplicate repo git:foo/bar also in category") do
        Catalog.read(catalog_path)
      end
    end
  end

  it "canonical with nil description" do
    with_tempdir("catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/bar
          description: A
        - git: foo/bar
        YAML
      Catalog.read(catalog_path)
    end
  end

  it "canonical with both nil description" do
    with_tempdir("catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/bar
        - git: foo/bar
        YAML
      Catalog.read(catalog_path)
    end
  end
end
