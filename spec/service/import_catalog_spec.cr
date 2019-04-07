require "spec"
require "../../src/service/import_catalog"
require "../support/jobs"
require "../support/db"
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

describe Service::ImportCatalog do
  it "imports shards" do
    with_tempdir("import_catalog") do |path|
      catalog_path = File.join(path, "catalog")
      FileUtils.mkdir_p(catalog_path)
      File.write(File.join(catalog_path, "bar.yml"), <<-YAML)
        name: Bar
        shards:
        - git: https://example.com/foo/foo.git
        - git: https://example.com/foo/bar.git
        YAML
      File.write(File.join(catalog_path, "foo.yml"), <<-YAML)
        name: Foo
        shards:
        - github: foo/foo
        - git: https://example.com/foo/bar.git
        YAML

      transaction do |db|
        Factory.create_repo(db, Repo::Ref.new("github", "foo/foo"))
        Service::ImportCatalog.new(catalog_path).import_catalog(db)

        results = db.connection.query_all <<-SQL, as: {String, String, Int64}
          SELECT
            resolver::text, url::text, id
          FROM
            repos
          SQL

        results.map{|result| {result[0], result[1]} }.should eq [
          {"github", "foo/foo"},
          {"git", "https://example.com/foo/foo.git"},
          {"git", "https://example.com/foo/bar.git"},
        ]

        enqueued_jobs.sort.should eq results.map {|result| {"Service::SyncRepo", %({"repo_id":#{result[2]}})} }[1, 2]
      end
    end
  end

  it "creates categories" do
    with_tempdir("import_catalog") do |path|
      catalog_path = File.join(path, "catalog")
      FileUtils.mkdir_p(catalog_path)
      File.write(File.join(catalog_path, "bar.yml"), <<-YAML)
        name: Bar
        description: bardesc
        shards:
        - github: foo/foo
        - git: https://example.com/foo/foo.git
        YAML
      File.write(File.join(catalog_path, "foo.yml"), <<-YAML)
        name: Foo
        description: foodesc
        shards:
        - github: foo/foo
        - git: https://example.com/foo/bar.git
        YAML

      transaction do |db|
        Service::ImportCatalog.new(catalog_path).import_catalog(db)
        db.all_categories.map { |cat| {cat.name, cat.description }}.should eq [{"Bar", "bardesc"}, {"Foo", "foodesc"}]
      end
    end
  end
end
