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

private def persisted_repos(db)
  db.connection.query_all <<-SQL, as: {String, String, String, Int64?}
    SELECT
      resolver::text, url::text, role::text, shard_id
    FROM
      repos
    ORDER BY
      url
    SQL
end

private def shard_categorizations(db)
  db.connection.query_all <<-SQL, as: {String, String, Array(String)?}
    SELECT
      name::text, qualifier::text,
      (SELECT array_agg(categories.slug::text ORDER BY slug) FROM categories WHERE shards.categories @> ARRAY[categories.id])
    FROM
      shards
    ORDER BY
      name, qualifier
    SQL
end

struct Service::ImportCatalog
  property mock_create_shard = false

  private def create_shard(db, entry, repo_id)
    if mock_create_shard
      # This avoids parsing shard spec
      Service::ImportShard.new(entry.repo_ref).create_shard(db, repo_id, entry.repo_ref.name, entry)
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

        shard_id = db.get_shard_id("foo")
        persisted_repos(db).should eq [
          {"git", "foo", "canonical", shard_id},
        ]
        shard_categorizations(db).should eq [
          {"foo", "", ["foo"]},
        ]

        repo_id = db.get_repo_id("git", "foo")
        db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
          {"import_catalog:repo:created", repo_id, nil, nil},
          {"import_shard:created", repo_id, shard_id, nil},
          {
            "import_catalog:done", nil, nil, {
              "new_categories"     => ["foo"],
              "deleted_categories" => [] of String,
              "updated_categories" => [] of String,
            },
          },
        ]
      end
    end
  end

  it "imports repos" do
    with_tempdir("import_catalog-repos") do |catalog_path|
      File.write(File.join(catalog_path, "bar.yml"), <<-YAML)
        name: Bar
        shards:
        - git: https://example.com/foo/baz.git
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

        persisted_repos(db).should eq [
          {"github", "foo/foo", "canonical", db.get_shard_id("foo")},
          {"git", "https://example.com/foo/bar.git", "canonical", db.get_shard_id("bar")},
          {"git", "https://example.com/foo/baz.git", "canonical", db.get_shard_id("baz")},
        ]
        shard_categorizations(db).should eq [
          {"bar", "", ["bar", "foo"]},
          {"baz", "", ["bar"]},
          {"foo", "", ["foo"]},
        ]

        baz_repo_id = db.get_repo_id("git", "https://example.com/foo/baz.git")
        bar_repo_id = db.get_repo_id("git", "https://example.com/foo/bar.git")
        db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
          {"import_catalog:repo:created", baz_repo_id, nil, nil},
          {"import_shard:created", baz_repo_id, db.get_shard_id("baz"), nil},
          {"import_catalog:repo:created", bar_repo_id, nil, nil},
          {"import_shard:created", bar_repo_id, db.get_shard_id("bar"), nil},
          {"import_shard:created", db.get_repo_id("github", "foo/foo"), db.get_shard_id("foo"), nil},
          {
            "import_catalog:done", nil, nil, {
              "new_categories"     => ["foo", "bar"],
              "deleted_categories" => [] of String,
              "updated_categories" => [] of String,
            },
          },
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

      transaction do |db|
        Factory.create_repo(db, Repo::Ref.new("git", "bar/foo"))
        service = Service::ImportCatalog.new(catalog_path)
        service.mock_create_shard = true
        service.import_catalog(db)

        foo_id = db.get_shard_id("foo")
        bar_id = db.get_shard_id("bar")

        persisted_repos(db).should eq [
          {"git", "bar/bar", "canonical", bar_id},
          {"git", "bar/foo", "mirror", foo_id},
          {"git", "baz/foo", "legacy", foo_id},
          {"git", "foo/bar", "legacy", bar_id},
          {"git", "foo/foo", "canonical", foo_id},
          {"git", "qux/foo", "legacy", foo_id},
        ]
        shard_categorizations(db).should eq [
          {"bar", "", ["category"]},
          {"foo", "", ["category"]},
        ]

        foo_repo_id = db.get_repo_id("git", "foo/foo")
        bar_repo_id = db.get_repo_id("git", "bar/bar")
        db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
          {"import_catalog:repo:created", foo_repo_id, nil, nil},
          {"import_shard:created", foo_repo_id, foo_id, nil},
          {"import_catalog:repo:created", bar_repo_id, nil, nil},
          {"import_shard:created", bar_repo_id, bar_id, nil},
          {
            "import_catalog:done", nil, nil, {
              "new_categories"     => ["category"],
              "deleted_categories" => [] of String,
              "updated_categories" => [] of String,
            },
          },
        ]
      end
    end
  end

  it "imports mirrors from different categories" do
    with_tempdir("import_catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category1.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/foo
          mirrors:
          - git: bar/foo
          - git: baz/foo
            role: legacy
        YAML
      File.write(File.join(catalog_path, "category2.yml"), <<-YAML)
        name: Category2
        shards:
        - git: foo/foo
          mirrors:
          - git: bar/bar
          - git: qux/foo
            role: legacy
        YAML

      transaction do |db|
        service = Service::ImportCatalog.new(catalog_path)
        service.mock_create_shard = true
        service.import_catalog(db)

        shard_id = db.get_shard_id("foo")

        persisted_repos(db).should eq [
          {"git", "bar/bar", "mirror", shard_id},
          {"git", "bar/foo", "mirror", shard_id},
          {"git", "baz/foo", "legacy", shard_id},
          {"git", "foo/foo", "canonical", shard_id},
          {"git", "qux/foo", "legacy", shard_id},
        ]
        shard_categorizations(db).should eq [
          {"foo", "", ["category1", "category2"]},
        ]
        foo_repo_id = db.get_repo_id("git", "foo/foo")
        db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
          {"import_catalog:repo:created", foo_repo_id, nil, nil},
          {"import_shard:created", foo_repo_id, shard_id, nil},
          {
            "import_catalog:done", nil, nil, {
              "new_categories"     => ["category1", "category2"],
              "deleted_categories" => [] of String,
              "updated_categories" => [] of String,
            },
          },
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
          mirrors:
          - git: bar/foo
          - git: baz/foo
            role: legacy
        YAML

      transaction do |db|
        shard_id = Factory.create_shard(db, "foo")
        Factory.create_repo(db, Repo::Ref.new("git", "foo/foo"), shard_id: shard_id)
        Factory.create_repo(db, Repo::Ref.new("git", "bar/bar"), shard_id: shard_id, role: :mirror)
        Factory.create_repo(db, Repo::Ref.new("git", "baz/bar"), shard_id: shard_id, role: :legacy)

        service = Service::ImportCatalog.new(catalog_path)
        service.mock_create_shard = true
        service.import_catalog(db)

        persisted_repos(db).should eq [
          {"git", "bar/bar", "obsolete", nil},
          {"git", "bar/foo", "mirror", shard_id},
          {"git", "baz/bar", "obsolete", nil},
          {"git", "baz/foo", "legacy", shard_id},
          {"git", "foo/foo", "canonical", shard_id},
        ]
        shard_categorizations(db).should eq [
          {"foo", "", ["category"]},
        ]

        db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
          {
            "import_catalog:done", nil, nil, {
              "new_categories"     => ["category"],
              "deleted_categories" => [] of String,
              "updated_categories" => [] of String,
            },
          },
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

        bar_shard_id = db.get_shard_id("bar")
        persisted_repos(db).should eq [
          {"git", "foo/bar", "canonical", bar_shard_id},
          {"git", "foo/foo", "canonical", foo_shard_id},
        ]
        shard_categorizations(db).should eq [
          {"bar", "", ["category"]},
          {"foo", "", ["category"]},
        ]
        foo_repo_id = db.get_repo_id("git", "foo/bar")
        db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
          {"import_catalog:repo:reactivated", foo_repo_id, nil, nil},
          {"import_shard:created", foo_repo_id, bar_shard_id, nil},
          {
            "import_catalog:done", nil, nil, {
              "new_categories"     => ["category"],
              "deleted_categories" => [] of String,
              "updated_categories" => [] of String,
            },
          },
        ]
      end
    end
  end

  it "deletes unreferenced shard" do
    with_tempdir("import_catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/foo
        YAML

      transaction do |db|
        foo_shard_id = Factory.create_shard(db, "foo")
        Factory.create_category(db, "bar")
        bar_shard_id = Factory.create_shard(db, "bar", categories: %w[bar])
        Factory.create_repo(db, Repo::Ref.new("git", "foo/foo"), shard_id: foo_shard_id)
        Factory.create_repo(db, Repo::Ref.new("git", "foo/bar"), shard_id: bar_shard_id)

        service = Service::ImportCatalog.new(catalog_path)
        service.mock_create_shard = true
        service.import_catalog(db)

        persisted_repos(db).should eq [
          {"git", "foo/bar", "obsolete", nil},
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
        shard_categorizations(db).should eq [
          {"foo", "", ["category"]},
        ]
        db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
          {
            "import_catalog:done", nil, nil, {
              "new_categories"     => ["category"],
              "deleted_categories" => ["bar"],
              "updated_categories" => [] of String,
            },
          },
        ]
      end
    end
  end

  it "obsoletes repo deleted from catalog, but keeps uncategorized" do
    with_tempdir("import_catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/foo
        YAML

      transaction do |db|
        Factory.create_repo(db, Repo::Ref.new("git", "bar/bar"), shard_id: nil)
        baz_id = Factory.create_shard(db, "baz")
        Factory.create_repo(db, Repo::Ref.new("git", "baz/baz"), shard_id: baz_id)
        Factory.create_category(db, "foo")
        qux_id = Factory.create_shard(db, "qux", categories: %w[foo])
        Factory.create_repo(db, Repo::Ref.new("git", "qux/qux"), shard_id: qux_id)

        service = Service::ImportCatalog.new(catalog_path)
        service.mock_create_shard = true
        service.import_catalog(db)

        persisted_repos(db).should eq [
          {"git", "bar/bar", "canonical", nil},
          {"git", "baz/baz", "canonical", baz_id},
          {"git", "foo/foo", "canonical", db.get_shard_id("foo")},
          {"git", "qux/qux", "obsolete", nil},
        ]
        shard_categorizations(db).should eq [
          {"baz", "", nil},
          {"foo", "", ["category"]},
        ]
        foo_repo_id = db.get_repo_id("git", "foo/foo")
        db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
          {"import_catalog:repo:created", foo_repo_id, nil, nil},
          {"import_shard:created", foo_repo_id, db.get_shard_id("foo"), nil},
          {
            "import_catalog:done", nil, nil, {
              "new_categories"     => ["category"],
              "deleted_categories" => ["foo"],
              "updated_categories" => [] of String,
            },
          },
        ]
      end
    end
  end

  it "handles shards marked as archived in catalog" do
    with_tempdir("import_catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/foo
          state: archived
        - git: foo/bar
          state: archived
        - git: foo/baz
        - git: foo/qux
          state: archived
        YAML

      transaction do |db|
        # existing shard, gets archived
        foo_id = Factory.create_shard(db, "foo")
        Factory.create_repo(db, Repo::Ref.new("git", "foo/foo"), shard_id: foo_id)
        # existing archived shard, gets unarchived
        baz_id = Factory.create_shard(db, "baz", archived_at: Time.utc)
        Factory.create_repo(db, Repo::Ref.new("git", "foo/baz"), shard_id: baz_id)
        # existing archived shard, stays archived
        qux_archived_at = Time.utc(2019, 10, 12, 13, 13)
        qux_id = Factory.create_shard(db, "qux", archived_at: qux_archived_at)
        Factory.create_repo(db, Repo::Ref.new("git", "foo/qux"), shard_id: qux_id)

        service = Service::ImportCatalog.new(catalog_path)
        service.mock_create_shard = true
        service.import_catalog(db)

        bar_id = db.get_shard_id("bar")
        persisted_repos(db).should eq [
          {"git", "foo/bar", "canonical", bar_id},
          {"git", "foo/baz", "canonical", baz_id},
          {"git", "foo/foo", "canonical", foo_id},
          {"git", "foo/qux", "canonical", qux_id},
        ]

        db.find_shard(foo_id).archived_at.not_nil!.should be_close(Time.utc, 1.second)
        db.find_shard(bar_id).archived_at.not_nil!.should be_close(Time.utc, 1.second)
        db.find_shard(baz_id).archived_at.should be_nil
        db.find_shard(qux_id).archived_at.should eq qux_archived_at

        bar_repo_id = db.get_repo_id("git", "foo/bar")
        db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
          {"import_catalog:repo:created", bar_repo_id, nil, nil},
          {"import_shard:created", bar_repo_id, bar_id, nil},
          {
            "import_catalog:done", nil, nil, {
              "new_categories"     => ["category"],
              "deleted_categories" => [] of String,
              "updated_categories" => [] of String,
            },
          },
        ]
      end
    end
  end

  it "deletes unreferenced shard and moves repo to mirror" do
    with_tempdir("import_catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/foo
          mirrors:
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

        persisted_repos(db).should eq [
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
        shard_categorizations(db).should eq [
          {"foo", "", ["category"]},
        ]

        db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
          {
            "import_catalog:done", nil, nil, {
              "new_categories"     => ["category"],
              "deleted_categories" => [] of String,
              "updated_categories" => [] of String,
            },
          },
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
      shard_categorizations(db).should eq [
        {"foo", "", nil},
      ]
    end
  end

  it "handles duplicate mirrors" do
    with_tempdir("import_catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/foo
          mirrors:
          - git: baz/baz
        - git: foo/bar
          mirrors:
          - git: baz/baz
        YAML

      transaction do |db|
        service = Service::ImportCatalog.new(catalog_path)
        service.mock_create_shard = true
        service.import_catalog(db)

        foo_id = db.get_shard_id("foo")
        bar_id = db.get_shard_id("bar")
        persisted_repos(db).should eq [
          {"git", "baz/baz", "mirror", bar_id},
          {"git", "foo/bar", "canonical", bar_id},
          {"git", "foo/foo", "canonical", foo_id},
        ]
        shard_categorizations(db).should eq [
          {"bar", "", ["category"]},
          {"foo", "", ["category"]},
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
        - git: bar/bar
        YAML
      File.write(File.join(catalog_path, "foo.yml"), <<-YAML)
        name: Foo
        description: foodesc
        shards:
        - git: foo/foo
        YAML

      transaction do |db|
        service = Service::ImportCatalog.new(catalog_path)
        service.mock_create_shard = true
        service.import_catalog(db)
        db.all_categories.map { |cat| {cat.name, cat.description} }.should eq [{"Bar", "bardesc"}, {"Foo", "foodesc"}]

        foo_id = db.get_shard_id("foo")
        bar_id = db.get_shard_id("bar")
        persisted_repos(db).should eq [
          {"git", "bar/bar", "canonical", bar_id},
          {"git", "foo/foo", "canonical", foo_id},
        ]
        shard_categorizations(db).should eq [
          {"bar", "", ["bar"]},
          {"foo", "", ["foo"]},
        ]
      end
    end
  end
end
