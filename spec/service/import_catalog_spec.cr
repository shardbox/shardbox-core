require "spec"
require "../../src/service/import_catalog"
require "../support/jobs"
require "../support/db"
require "../support/raven"
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

struct Service::ImportCatalog
  property mock_create_shard = false

  private def create_shard(db, entry, repo_id)
    if mock_create_shard
      shard_id = db.create_shard(Shard.new(entry.repo_ref.name, "id#{repo_id}"))

      db.connection.exec <<-SQL, repo_id, shard_id
        UPDATE
          repos
        SET
          shard_id = $2,
          sync_failed_at = NULL
        WHERE
          id = $1 AND shard_id IS NULL
        SQL
      shard_id
    else
      previous_def
    end
  end
end

describe Service::ImportCatalog do
  it "imports repo" do
    with_tempdir("import_catalog-repo") do |catalog_path|
      File.write(File.join(catalog_path, "foo.yml"), <<-YAML)
        name: Foo
        shards:
        - git: foo
        YAML

      transaction do |db|
        service = Service::ImportCatalog.new(catalog_path)
        service.mock_create_shard = true
        service.import_catalog(db)

        results = db.connection.query_all <<-SQL, as: {String, String}
          SELECT
            resolver::text, url::text
          FROM
            repos
          SQL

        results.should eq [
          {"git", "foo"},
        ]
      end
    end
  end

  it "imports repos" do
    with_tempdir("import_catalog-repos") do |catalog_path|
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
        service = Service::ImportCatalog.new(catalog_path)
        service.mock_create_shard = true
        service.import_catalog(db)

        results = db.connection.query_all <<-SQL, as: {String, String}
          SELECT
            resolver::text, url::text
          FROM
            repos
          ORDER BY
            url
          SQL

        results.should eq [
          {"github", "foo/foo"},
          {"git", "https://example.com/foo/bar.git"},
          {"git", "https://example.com/foo/foo.git"},
        ]
      end
    end
  end

  it "imports mirrors" do
    with_tempdir("import_catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/foo
          mirror:
          - git: bar/foo
          - git: bar/bar
          legacy:
          - git: baz/foo
          - git: qux/foo
        YAML

      transaction do |db|
        Factory.create_repo(db, Repo::Ref.new("git", "bar/foo"))
        service = Service::ImportCatalog.new(catalog_path)
        service.mock_create_shard = true
        service.import_catalog(db)

        shard_id = db.get_repo_shard_id("git", "foo/foo")

        results = db.connection.query_all <<-SQL, as: {String, String, String, Int64?}
          SELECT
            resolver::text, url::text, role::text, shard_id
          FROM
            repos
          ORDER BY
            url
          SQL
        results.should eq [
          {"git", "bar/bar", "mirror", shard_id},
          {"git", "bar/foo", "mirror", shard_id},
          {"git", "baz/foo", "legacy", shard_id},
          {"git", "foo/foo", "canonical", shard_id},
          {"git", "qux/foo", "legacy", shard_id},
        ]
      end
    end
  end

  it "imports mirrors from different categories" do
    with_tempdir("import_catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/foo
          mirror:
          - git: bar/foo
          legacy:
          - git: baz/foo
        YAML
      File.write(File.join(catalog_path, "category2.yml"), <<-YAML)
        name: Category2
        shards:
        - git: foo/foo
          mirror:
          - git: bar/bar
          legacy:
          - git: qux/foo
        YAML

      transaction do |db|
        service = Service::ImportCatalog.new(catalog_path)
        service.mock_create_shard = true
        service.import_catalog(db)

        shard_id = db.get_repo_shard_id("git", "foo/foo")

        results = db.connection.query_all <<-SQL, as: {String, String, String, Int64?}
          SELECT
            resolver::text, url::text, role::text, shard_id
          FROM
            repos
          ORDER BY url
          SQL
        results.should eq [
          {"git", "bar/bar", "mirror", shard_id},
          {"git", "bar/foo", "mirror", shard_id},
          {"git", "baz/foo", "legacy", shard_id},
          {"git", "foo/foo", "canonical", shard_id},
          {"git", "qux/foo", "legacy", shard_id},
        ]
      end
    end
  end

  it "updates mirrors" do
    with_tempdir("import_catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/foo
          mirror:
          - git: bar/foo
          legacy:
          - git: baz/foo
        YAML

      transaction do |db|
        shard_id = Factory.create_shard(db, "foo")
        Factory.create_repo(db, Repo::Ref.new("git", "foo/foo"), shard_id: shard_id)
        Factory.create_repo(db, Repo::Ref.new("git", "bar/bar"), shard_id: shard_id, role: :mirror)
        Factory.create_repo(db, Repo::Ref.new("git", "baz/bar"), shard_id: shard_id, role: :legacy)

        service = Service::ImportCatalog.new(catalog_path)
        service.mock_create_shard = true
        service.import_catalog(db)

        results = db.connection.query_all <<-SQL, as: {String, String, String, Int64?}
          SELECT
            resolver::text, url::text, role::text, shard_id
          FROM
            repos
          ORDER BY url
          SQL

        results.should eq [
          {"git", "bar/bar", "obsolete", nil},
          {"git", "bar/foo", "mirror", shard_id},
          {"git", "baz/bar", "obsolete", nil},
          {"git", "baz/foo", "legacy", shard_id},
          {"git", "foo/foo", "canonical", shard_id},
        ]
      end
    end
  end

  it "updates mirrors and creates new shard" do
    with_tempdir("import_catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/foo
        - git: foo/bar
        YAML

      transaction do |db|
        foo_shard_id = Factory.create_shard(db, "foo")
        Factory.create_repo(db, Repo::Ref.new("git", "foo/foo"), shard_id: foo_shard_id)
        Factory.create_repo(db, Repo::Ref.new("git", "foo/bar"), shard_id: foo_shard_id, role: :mirror)

        service = Service::ImportCatalog.new(catalog_path)
        service.mock_create_shard = true
        service.import_catalog(db)

        results = db.connection.query_all <<-SQL, as: {String, String, String, Int64?}
          SELECT
            resolver::text, url::text, role::text, shard_id
          FROM
            repos
          ORDER BY url
          SQL

        bar_shard_id = db.get_repo_shard_id("git", "foo/bar")
        results.should eq [
          {"git", "foo/bar", "canonical", bar_shard_id},
          {"git", "foo/foo", "canonical", foo_shard_id},
        ]
      end
    end
  end

  it "updates mirrors and deletes old shard" do
    with_tempdir("import_catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/foo
          mirror:
          - git: foo/bar
        YAML

      transaction do |db|
        foo_shard_id = Factory.create_shard(db, "foo")
        bar_shard_id = Factory.create_shard(db, "bar")
        Factory.create_repo(db, Repo::Ref.new("git", "foo/foo"), shard_id: foo_shard_id)
        Factory.create_repo(db, Repo::Ref.new("git", "foo/bar"), shard_id: bar_shard_id)

        service = Service::ImportCatalog.new(catalog_path)
        service.mock_create_shard = true
        service.import_catalog(db)

        results = db.connection.query_all <<-SQL, as: {String, String, String, Int64?}
          SELECT
            resolver::text, url::text, role::text, shard_id
          FROM
            repos
          ORDER BY url
          SQL

        results.should eq [
          {"git", "foo/bar", "mirror", foo_shard_id},
          {"git", "foo/foo", "canonical", foo_shard_id},
        ]

        results = db.connection.query_all <<-SQL, as: {Int64, String}
          SELECT
            id, name::text
          FROM
            shards
          ORDER BY name
          SQL
        results.should eq [
          {foo_shard_id, "foo"},
        ]
      end
    end
  end

  it "#delete_unreferenced_shards" do
    transaction do |db|
      bar_id = Factory.create_shard(db, "bar")
      Factory.create_release(db, bar_id)
      foo_id = Factory.create_shard(db, "foo")
      Factory.create_repo(db, Repo::Ref.new("git", "foo/foo"), shard_id: foo_id)

      service = Service::ImportCatalog.new("")
      service.delete_unreferenced_shards(db)

      results = db.connection.query_all <<-SQL, as: {Int64, String}
        SELECT
          id, name::text
        FROM
          shards
        SQL
      results.should eq [
        {foo_id, "foo"},
      ]

      releases_count = db.connection.query_one <<-SQL, as: Int64
        SELECT
          COUNT(*)
        FROM
          releases
        SQL
      releases_count.should eq 0
    end
  end

  it "handles duplicate mirrors" do
    with_tempdir("import_catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/foo
          mirror:
          - git: baz/baz
        - git: foo/bar
          mirror:
          - git: baz/baz
        YAML

      transaction do |db|
        service = Service::ImportCatalog.new(catalog_path)
        service.mock_create_shard = true
        service.import_catalog(db)

        results = db.connection.query_all <<-SQL, as: {String, String, String, Int64?}
          SELECT
            resolver::text, url::text, role::text, shard_id
          FROM
            repos
          ORDER BY url
          SQL

        foo_id = db.get_repo_shard_id("git", "foo/foo")
        bar_id = db.get_repo_shard_id("git", "foo/bar")
        results.should eq [
          {"git", "baz/baz", "mirror", bar_id},
          {"git", "foo/bar", "canonical", bar_id},
          {"git", "foo/foo", "canonical", foo_id},
        ]
      end
    end
  end

  it "creates categories" do
    with_tempdir("import_catalog") do |catalog_path|
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
        service = Service::ImportCatalog.new(catalog_path)
        service.mock_create_shard = true
        service.import_catalog(db)
        db.all_categories.map { |cat| {cat.name, cat.description} }.should eq [{"Bar", "bardesc"}, {"Foo", "foodesc"}]
      end
    end
  end
end
