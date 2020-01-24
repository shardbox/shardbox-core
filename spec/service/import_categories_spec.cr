require "spec"
require "../../src/service/import_categories"
require "../../src/catalog"
require "../support/db"
require "../support/raven"
require "../support/tempdir"

describe Service::ImportCategories do
  it "creates category" do
    with_tempdir("import_categories") do |catalog_path|
      transaction do |db|
        File.write(File.join(catalog_path, "bar.yml"), <<-YAML)
          name: Bar
          description: bardesc
          YAML

        catalog = Catalog.read(catalog_path)
        service = Service::ImportCategories.new(db, catalog)

        import_stats = service.perform
        db.all_categories.map { |cat| {cat.name, cat.description} }.should eq [{"Bar", "bardesc"}]

        import_stats.should eq({
          "deleted_categories" => [] of String,
          "new_categories"     => ["bar"],
          "updated_categories" => [] of String,
        })
      end
    end
  end

  it "deletes category" do
    with_tempdir("import_categories") do |catalog_path|
      transaction do |db|
        db.create_category(Category.new("foo", "Foo", "Foo Description"))

        catalog = Catalog.new(catalog_path)
        service = Service::ImportCategories.new(db, catalog)

        import_stats = service.perform
        db.all_categories.should be_empty

        import_stats.should eq({
          "deleted_categories" => ["foo"],
          "new_categories"     => [] of String,
          "updated_categories" => [] of String,
        })
      end
    end
  end

  it "is idempotent" do
    with_tempdir("import_categories") do |catalog_path|
      File.write(File.join(catalog_path, "foo.yml"), <<-YAML)
        name: Foo
        description: Foo Description
        YAML

      transaction do |db|
        db.create_category(Category.new("foo", "Foo", "Foo Description"))

        catalog = Catalog.read(catalog_path)
        service = Service::ImportCategories.new(db, catalog)

        import_stats = service.perform
        db.all_categories.map { |cat| {cat.name, cat.description} }.should eq [{"Foo", "Foo Description"}]

        import_stats.should eq({
          "deleted_categories" => [] of String,
          "new_categories"     => [] of String,
          "updated_categories" => [] of String,
        })
      end
    end
  end

  it "updates category" do
    with_tempdir("import_categories") do |catalog_path|
      File.write(File.join(catalog_path, "foo.yml"), <<-YAML)
        name: New Foo
        description: New Foo Description
        YAML

      transaction do |db|
        db.create_category(Category.new("foo", "Foo", "Foo Description"))

        catalog = Catalog.read(catalog_path)
        service = Service::ImportCategories.new(db, catalog)

        import_stats = service.perform
        db.all_categories.map { |cat| {cat.name, cat.description} }.should eq [{"New Foo", "New Foo Description"}]

        import_stats.should eq({
          "deleted_categories" => [] of String,
          "new_categories"     => [] of String,
          "updated_categories" => ["foo"],
        })
      end
    end
  end
end
