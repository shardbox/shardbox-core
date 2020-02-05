require "spec"
require "../../src/service/import_catalog"
require "../../src/service/create_shard"
require "../support/db"
require "../support/raven"
require "../support/tempdir"

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
    WHERE
      archived_at IS NULL OR categories <> '{}'
    ORDER BY
      name, qualifier
    SQL
end

private def last_activities(db)
  db.last_activities.select { |a| a.event != "import_categories:finished" }.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }
end

struct Service::ImportCatalog
  property mock_create_shard = false

  private def create_shard(entry, repo)
    if mock_create_shard
      # This avoids parsing shard spec in ImportShard
      Service::CreateShard.new(@db, repo, entry.repo_ref.name, entry).perform
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
        service = Service::ImportCatalog.new(db, catalog_path)
        service.mock_create_shard = true
        service.import_catalog

        shard_id = db.get_shard_id("foo")
        persisted_repos(db).should eq [
          {"git", "foo", "canonical", shard_id},
        ]
        shard_categorizations(db).should eq [
          {"foo", "", ["foo"]},
        ]

        repo_id = db.get_repo_id("git", "foo")
        db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
          {"import_categories:finished", nil, nil, {
            "new_categories"     => ["foo"],
            "deleted_categories" => [] of String,
            "updated_categories" => [] of String,
          }},
          {"import_catalog:repo:created", repo_id, nil, nil},
          {"create_shard:created", repo_id, shard_id, nil},
        ]
        service.stats(0.seconds).should eq({
          "elapsed"         => 0.seconds.to_s,
          "new_repos"       => ["git:foo"],
          "obsolete_repos"  => [] of String,
          "archived_shards" => [] of Int64,
        })
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
        service = Service::ImportCatalog.new(db, catalog_path)
        service.mock_create_shard = true
        import_stats = service.import_catalog

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
          {"import_categories:finished", nil, nil, {
            "new_categories"     => ["foo", "bar"],
            "deleted_categories" => [] of String,
            "updated_categories" => [] of String,
          }},
          {"import_catalog:repo:created", baz_repo_id, nil, nil},
          {"create_shard:created", baz_repo_id, db.get_shard_id("baz"), nil},
          {"import_catalog:repo:created", bar_repo_id, nil, nil},
          {"create_shard:created", bar_repo_id, db.get_shard_id("bar"), nil},
          {"create_shard:created", db.get_repo_id("github", "foo/foo"), db.get_shard_id("foo"), nil},
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
        service = Service::ImportCatalog.new(db, catalog_path)
        service.mock_create_shard = true
        import_stats = service.import_catalog

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
          {"import_categories:finished", nil, nil, {
            "new_categories"     => ["category"],
            "deleted_categories" => [] of String,
            "updated_categories" => [] of String,
          }},
          {"import_catalog:repo:created", foo_repo_id, nil, nil},
          {"create_shard:created", foo_repo_id, foo_id, nil},
          {"import_catalog:mirror:switched", db.get_repo_id("git", "bar/foo"), foo_id, {"role" => "mirror", "old_role" => "canonical", "old_shard_id" => nil}},
          {"import_catalog:mirror:created", db.get_repo_id("git", "baz/foo"), foo_id, {"role" => "legacy"}},
          {"import_catalog:mirror:created", db.get_repo_id("git", "qux/foo"), foo_id, {"role" => "legacy"}},
          {"import_catalog:repo:created", bar_repo_id, nil, nil},
          {"create_shard:created", bar_repo_id, bar_id, nil},
          {"import_catalog:mirror:created", db.get_repo_id("git", "foo/bar"), bar_id, {"role" => "legacy"}},
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
        service = Service::ImportCatalog.new(db, catalog_path)
        service.mock_create_shard = true
        import_stats = service.import_catalog

        foo_id = db.get_shard_id("foo")

        persisted_repos(db).should eq [
          {"git", "bar/bar", "mirror", foo_id},
          {"git", "bar/foo", "mirror", foo_id},
          {"git", "baz/foo", "legacy", foo_id},
          {"git", "foo/foo", "canonical", foo_id},
          {"git", "qux/foo", "legacy", foo_id},
        ]
        shard_categorizations(db).should eq [
          {"foo", "", ["category1", "category2"]},
        ]
        foo_repo_id = db.get_repo_id("git", "foo/foo")

        db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
          {"import_categories:finished", nil, nil, {
            "new_categories"     => ["category1", "category2"],
            "deleted_categories" => [] of String,
            "updated_categories" => [] of String,
          }},
          {"import_catalog:repo:created", foo_repo_id, nil, nil},
          {"create_shard:created", foo_repo_id, foo_id, nil},
          {"import_catalog:mirror:created", db.get_repo_id("git", "bar/foo"), foo_id, {"role" => "mirror"}},
          {"import_catalog:mirror:created", db.get_repo_id("git", "baz/foo"), foo_id, {"role" => "legacy"}},
          {"import_catalog:mirror:created", db.get_repo_id("git", "bar/bar"), foo_id, {"role" => "mirror"}},
          {"import_catalog:mirror:created", db.get_repo_id("git", "qux/foo"), foo_id, {"role" => "legacy"}},
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
        foo_id = Factory.create_shard(db, "foo")
        Factory.create_repo(db, Repo::Ref.new("git", "foo/foo"), shard_id: foo_id)
        Factory.create_repo(db, Repo::Ref.new("git", "bar/bar"), shard_id: foo_id, role: :mirror)
        Factory.create_repo(db, Repo::Ref.new("git", "baz/bar"), shard_id: foo_id, role: :legacy)

        service = Service::ImportCatalog.new(db, catalog_path)
        service.mock_create_shard = true
        import_stats = service.import_catalog

        persisted_repos(db).should eq [
          {"git", "bar/bar", "obsolete", nil},
          {"git", "bar/foo", "mirror", foo_id},
          {"git", "baz/bar", "obsolete", nil},
          {"git", "baz/foo", "legacy", foo_id},
          {"git", "foo/foo", "canonical", foo_id},
        ]
        shard_categorizations(db).should eq [
          {"foo", "", ["category"]},
        ]

        db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
          {"import_categories:finished", nil, nil, {
            "new_categories"     => ["category"],
            "deleted_categories" => [] of String,
            "updated_categories" => [] of String,
          }},
          {"import_catalog:mirror:created", db.get_repo_id("git", "bar/foo"), foo_id, {"role" => "mirror"}},
          {"import_catalog:mirror:created", db.get_repo_id("git", "baz/foo"), foo_id, {"role" => "legacy"}},
          {"import_catalog:repo:obsoleted", db.get_repo_id("git", "baz/bar"), foo_id, {"old_role" => "legacy"}},
          {"import_catalog:repo:obsoleted", db.get_repo_id("git", "bar/bar"), foo_id, {"old_role" => "mirror"}},
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

        service = Service::ImportCatalog.new(db, catalog_path)
        service.mock_create_shard = true
        import_stats = service.import_catalog

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
          {"import_categories:finished", nil, nil, {
            "new_categories"     => ["category"],
            "deleted_categories" => [] of String,
            "updated_categories" => [] of String,
          }},
          {"import_catalog:repo:obsoleted", foo_repo_id, foo_shard_id, {"old_role" => "mirror"}},
          {"import_catalog:repo:reactivated", foo_repo_id, nil, nil},
          {"create_shard:created", foo_repo_id, bar_shard_id, nil},
        ]
      end
    end
  end

  it "archives unreferenced shard" do
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
        bar_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "foo/bar"), shard_id: bar_shard_id)

        service = Service::ImportCatalog.new(db, catalog_path)
        service.mock_create_shard = true
        import_stats = service.import_catalog

        persisted_repos(db).should eq [
          {"git", "foo/bar", "obsolete", nil},
          {"git", "foo/foo", "canonical", foo_shard_id},
        ]

        db.get_shards.map { |shard| {shard.id, shard.name} }.should eq [
          {foo_shard_id, "foo"},
        ]
        shard_categorizations(db).should eq [
          {"foo", "", ["category"]},
        ]
        db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
          {"import_categories:finished", nil, nil, {
            "new_categories"     => ["category"],
            "deleted_categories" => ["bar"],
            "updated_categories" => [] of String,
          }},
          {"import_catalog:repo:obsoleted", bar_repo_id, bar_shard_id, {"old_role" => "canonical"}},
          {"import_catalog:shard:archived", nil, bar_shard_id, nil},
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
        qux_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "qux/qux"), shard_id: qux_id)

        service = Service::ImportCatalog.new(db, catalog_path)
        service.mock_create_shard = true
        import_stats = service.import_catalog

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
          {"import_categories:finished", nil, nil, {
            "new_categories"     => ["category"],
            "deleted_categories" => ["foo"],
            "updated_categories" => [] of String,
          }},
          {"import_catalog:repo:created", foo_repo_id, nil, nil},
          {"create_shard:created", foo_repo_id, db.get_shard_id("foo"), nil},
          {"import_catalog:repo:obsoleted", qux_repo_id, qux_id, {"old_role" => "canonical"}},
          {"import_catalog:shard:archived", nil, qux_id, nil},
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

        service = Service::ImportCatalog.new(db, catalog_path)
        service.mock_create_shard = true
        import_stats = service.import_catalog

        bar_id = db.get_shard_id("bar")
        persisted_repos(db).should eq [
          {"git", "foo/bar", "canonical", bar_id},
          {"git", "foo/baz", "canonical", baz_id},
          {"git", "foo/foo", "canonical", foo_id},
          {"git", "foo/qux", "canonical", qux_id},
        ]

        db.get_shard(foo_id).archived_at.not_nil!.should be_close(Time.utc, 1.second)
        db.get_shard(bar_id).archived_at.not_nil!.should be_close(Time.utc, 1.second)
        db.get_shard(baz_id).archived_at.should be_nil
        db.get_shard(qux_id).archived_at.should eq qux_archived_at

        bar_repo_id = db.get_repo_id("git", "foo/bar")
        db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
          {"import_categories:finished", nil, nil, {
            "new_categories"     => ["category"],
            "deleted_categories" => [] of String,
            "updated_categories" => [] of String,
          }},
          {"update_shard:archived", nil, foo_id, nil},
          {"import_catalog:repo:created", bar_repo_id, nil, nil},
          {"create_shard:created", bar_repo_id, bar_id, nil},
          {"update_shard:unarchived", nil, baz_id, nil},
        ]
      end
    end
  end

  it "archives unreferenced shard and moves repo to mirror" do
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

        service = Service::ImportCatalog.new(db, catalog_path)
        service.mock_create_shard = true
        import_stats = service.import_catalog

        persisted_repos(db).should eq [
          {"git", "foo/bar", "mirror", foo_shard_id},
          {"git", "foo/foo", "canonical", foo_shard_id},
        ]

        db.get_shards.map { |shard| {shard.id, shard.name} }.should eq [
          {foo_shard_id, "foo"},
        ]
        shard_categorizations(db).should eq [
          {"foo", "", ["category"]},
        ]

        db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
          {"import_categories:finished", nil, nil, {
            "new_categories"     => ["category"],
            "deleted_categories" => [] of String,
            "updated_categories" => [] of String,
          }},
          {
            "import_catalog:mirror:switched", db.get_repo_id("git", "foo/bar"), foo_shard_id, {
              "role"         => "mirror",
              "old_role"     => "canonical",
              "old_shard_id" => bar_shard_id,
            },
          },
          {"import_catalog:shard:archived", nil, bar_shard_id, nil},
        ]
      end
    end
  end

  it "archives and re-activates shard" do
    with_tempdir("import_catalog-mirrors") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: category
        shards: []
        YAML

      transaction do |db|
        category_id = Factory.create_category(db, "category")
        foo_shard_id = Factory.create_shard(db, "foo", categories: ["category"])
        foo_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "foo/foo"), shard_id: foo_shard_id)

        service = Service::ImportCatalog.new(db, catalog_path)
        service.mock_create_shard = true
        import_stats = service.import_catalog

        persisted_repos(db).should eq [
          {"git", "foo/foo", "obsolete", nil},
        ]
        db.get_shards.should be_empty

        # Shards list is empty, but archived shard can be retrieved by id
        shard = db.get_shard(foo_shard_id)
        shard.display_name.should eq "foo"
        shard.archived_at.should_not be_nil

        File.write(File.join(catalog_path, "category.yml"), <<-YAML)
          name: category
          shards:
          - git: foo/foo
          YAML

        service = Service::ImportCatalog.new(db, catalog_path)
        service.mock_create_shard = true
        import_stats = service.import_catalog

        persisted_repos(db).should eq [
          {"git", "foo/foo", "canonical", foo_shard_id},
        ]
        db.get_shards.map { |shard| {shard.id, shard.name, shard.qualifier, shard.archived_at} }.should eq [
          {foo_shard_id, "foo", "", nil},
        ]

        last_activities(db).should eq [
          {"import_catalog:repo:obsoleted", foo_repo_id, foo_shard_id, {"old_role" => "canonical"}},
          {"import_catalog:shard:archived", nil, foo_shard_id, nil},
          {"import_catalog:repo:reactivated", foo_repo_id, nil, nil},
          {"update_shard:unarchived", nil, foo_shard_id, nil},
        ]
      end
    end
  end

  it "reactivates obsolete repo" do
    with_tempdir("import_catalog-reactivate") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/foo
        YAML

      transaction do |db|
        foo_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "foo/foo"), shard_id: nil, role: :obsolete)

        service = Service::ImportCatalog.new(db, catalog_path)
        service.mock_create_shard = true
        import_stats = service.import_catalog

        shard_categorizations(db).should eq [
          {"foo", "", ["category"]},
        ]
        foo_id = db.get_shard_id("foo")
        persisted_repos(db).should eq [
          {"git", "foo/foo", "canonical", foo_id},
        ]

        last_activities(db).should eq [
          {"import_catalog:repo:reactivated", foo_repo_id, nil, nil},
          {"create_shard:created", foo_repo_id, foo_id, nil},
        ]
      end
    end
  end

  it "takes over mirror repo from same shard, old canonical obsoleted" do
    with_tempdir("import_catalog-reactivate") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/foo
        YAML

      transaction do |db|
        foo_id = Factory.create_shard(db, "foo")
        bar_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "bar/foo"), shard_id: foo_id, role: :canonical)
        foo_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "foo/foo"), shard_id: foo_id, role: :mirror)

        service = Service::ImportCatalog.new(db, catalog_path)
        service.mock_create_shard = true
        import_stats = service.import_catalog

        shard_categorizations(db).should eq [
          {"foo", "", ["category"]},
        ]
        persisted_repos(db).should eq [
          {"git", "bar/foo", "obsolete", nil},
          {"git", "foo/foo", "canonical", foo_id},
        ]

        last_activities(db).should eq [
          {"import_catalog:shard:canonical_switched", foo_repo_id, foo_id, {"old_repo" => "git:bar/foo"}},
        ]
      end
    end
  end

  it "takes over mirror repo from other shard" do
    with_tempdir("import_catalog-reactivate") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: foo/foo
        - git: foo/bar
        YAML

      transaction do |db|
        bar_id = Factory.create_shard(db, "bar")
        Factory.create_repo(db, Repo::Ref.new("git", "foo/bar"), shard_id: bar_id, role: :canonical)
        foo_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "foo/foo"), shard_id: bar_id, role: :mirror)

        service = Service::ImportCatalog.new(db, catalog_path)
        service.mock_create_shard = true
        import_stats = service.import_catalog

        foo_id = db.get_shard_id("foo")
        persisted_repos(db).should eq [
          {"git", "foo/bar", "canonical", bar_id},
          {"git", "foo/foo", "canonical", foo_id},
        ]
        shard_categorizations(db).should eq [
          {"bar", "", ["category"]},
          {"foo", "", ["category"]},
        ]

        last_activities(db).should eq [
          {"create_shard:created", foo_repo_id, foo_id, nil},
        ]
      end
    end
  end

  it "takes over canonical repo" do
    with_tempdir("import_catalog-reactivate") do |catalog_path|
      File.write(File.join(catalog_path, "category.yml"), <<-YAML)
        name: Category
        shards:
        - git: new/foo
          mirrors:
          - git: old/foo
        YAML

      transaction do |db|
        foo_id = Factory.create_shard(db, "foo")
        old_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "old/foo"), shard_id: foo_id, role: :canonical)
        new_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "new/foo"), shard_id: foo_id, role: :mirror)

        service = Service::ImportCatalog.new(db, catalog_path)
        service.mock_create_shard = true
        import_stats = service.import_catalog

        shard_categorizations(db).should eq [
          {"foo", "", ["category"]},
        ]
        persisted_repos(db).should eq [
          {"git", "new/foo", "canonical", foo_id},
          {"git", "old/foo", "mirror", foo_id},
        ]

        last_activities(db).should eq [
          {"import_catalog:shard:canonical_switched", new_repo_id, foo_id, {"old_repo" => "git:old/foo"}},
        ]
      end
    end
  end

  it "#archive_unreferenced_shards" do
    transaction do |db|
      bar_id = Factory.create_shard(db, "bar")
      Factory.create_release(db, bar_id)
      foo_id = Factory.create_shard(db, "foo")
      foo_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "foo/foo"), shard_id: foo_id)

      service = Service::ImportCatalog.new(db, Catalog.empty)
      service.archive_unreferenced_shards

      db.get_shards.map { |shard| {shard.id, shard.name} }.should eq [
        {foo_id, "foo"},
      ]
      # archived shard can be retrieved by id
      shard = db.get_shard(bar_id)
      shard.display_name.should eq "bar"
      shard.archived_at.should_not be_nil
      archived_at = shard.archived_at.not_nil!
      archived_at.should be_close(Time.utc, 1.seconds)

      releases_count = db.connection.query_one <<-SQL, as: Int64
        SELECT
          COUNT(*)
        FROM
          releases
        SQL
      # Doesn't delete releases
      releases_count.should eq 1
      shard_categorizations(db).should eq [
        {"foo", "", nil},
      ]
      last_activities(db).should eq [
        {"import_catalog:shard:archived", nil, bar_id, nil},
      ]

      # Test idempotency
      service.archive_unreferenced_shards

      shard = db.get_shard(bar_id)
      shard.display_name.should eq "bar"
      shard.archived_at.should eq archived_at

      last_activities(db).should eq [
        {"import_catalog:shard:archived", nil, bar_id, nil},
      ]
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
        service = Service::ImportCatalog.new(db, catalog_path)
        service.mock_create_shard = true
        service.import_catalog
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
