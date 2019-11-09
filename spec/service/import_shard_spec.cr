require "spec"
require "../support/raven"
require "../../src/service/import_shard"
require "../../src/catalog"
require "../support/db"
require "../support/jobs"
require "../support/mock_resolver"

private def persisted_shards(db)
  db.connection.query_all <<-SQL, as: {String, String, String?}
        SELECT
          name::text, qualifier::text, description::text
        FROM shards
        SQL
end

private def persisted_repos(db)
  db.connection.query_all <<-SQL, as: {String, String, String, String}
        SELECT
          resolver::text, url::text, role::text, shards.name::text
        FROM repos
        JOIN shards ON shards.id = repos.shard_id
        SQL
end

private def shard_categorizations(db)
  db.connection.query_all <<-SQL, as: {String, String, Array(String)?}
    SELECT
      name::text, qualifier::text,
      (SELECT array_agg(categories.slug::text) FROM categories WHERE shards.categories @> ARRAY[categories.id])
    FROM
      shards
    ORDER BY
      name, qualifier
    SQL
end

describe Service::ImportShard do
  mock_resolver = MockResolver.new
  mock_resolver.register("0.1.0", Factory.build_revision_info, <<-SPEC)
    name: test
    description: test shard
    version: 0.1.0
    SPEC

  it "fetches new shard" do
    repo_ref = Repo::Ref.new("git", "mock:test")
    service = Service::ImportShard.new(repo_ref)

    transaction do |db|
      shard_id = service.import_shard(db,
        Repo::Resolver.new(mock_resolver, repo_ref),
        Catalog::Entry.new(repo_ref, description: "foo description")
      )

      persisted_shards(db).should eq [{"test", "", "foo description"}]
      persisted_repos(db).should eq [{"git", "mock:test", "canonical", "test"}]

      repo_id = db.get_repo(repo_ref).id
      find_queued_tasks("Service::SyncRepo").map(&.arguments).should eq [%({"repo_ref":#{repo_ref.to_json}})]

      shard_categorizations(db).should eq [
        {"test", "", nil},
      ]

      db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
        {"import_shard:repo:created", repo_id, nil, nil},
        {"import_shard:created", repo_id, shard_id, nil},
      ]
    end
  end

  it "adds categories" do
    repo_ref = Repo::Ref.new("git", "mock:test")
    service = Service::ImportShard.new(repo_ref)

    transaction do |db|
      Factory.create_category(db, "foo")

      shard_id = service.import_shard(db,
        Repo::Resolver.new(mock_resolver, repo_ref),
        Catalog::Entry.new(repo_ref, description: "foo description", categories: ["foo"])
      )

      shard_categorizations(db).should eq [
        {"test", "", ["foo"]},
      ]

      repo_id = db.get_repo(repo_ref).id
      db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
        {"import_shard:repo:created", repo_id, nil, nil},
        {"import_shard:created", repo_id, shard_id, nil},
      ]
    end
  end

  describe "duplicate name" do
    it "with git resolver" do
      repo_ref = Repo::Ref.new("git", "mock://example.com/git/test.git")
      service = Service::ImportShard.new(repo_ref)

      transaction do |db|
        Factory.create_shard(db, "test")

        shard_id = service.import_shard(db, Repo::Resolver.new(mock_resolver, repo_ref))

        persisted_shards(db).should eq [{"test", "", nil}, {"test", "example.com", nil}]
        persisted_repos(db).should eq [{"git", "mock://example.com/git/test.git", "canonical", "test"}]

        find_queued_tasks("Service::SyncRepo").map(&.arguments).should eq [%({"repo_ref":#{repo_ref.to_json}})]
      end
    end

    it "with github resolver" do
      repo_ref = Repo::Ref.new("github", "testorg/test")
      service = Service::ImportShard.new(repo_ref)

      transaction do |db|
        Factory.create_shard(db, "test")

        shard_id = service.import_shard(db, Repo::Resolver.new(mock_resolver, repo_ref))

        persisted_shards(db).should eq [{"test", "", nil}, {"test", "testorg", nil}]
        persisted_repos(db).should eq [{"github", "testorg/test", "canonical", "test"}]

        find_queued_tasks("Service::SyncRepo").map(&.arguments).should eq [%({"repo_ref":#{repo_ref.to_json}})]
      end
    end

    it "with existing qualifier" do
      repo_ref = Repo::Ref.new("git", "mock://example.com/git/test.git")
      service = Service::ImportShard.new(repo_ref)

      transaction do |db|
        Factory.create_shard(db, "test")
        Factory.create_shard(db, "test", qualifier: "example.com")

        shard_id = service.import_shard(db, Repo::Resolver.new(mock_resolver, repo_ref))

        persisted_shards(db).should eq [{"test", "", nil}, {"test", "example.com", nil}, {"test", "example.com-git", nil}]
        persisted_repos(db).should eq [{"git", "mock://example.com/git/test.git", "canonical", "test"}]

        find_queued_tasks("Service::SyncRepo").map(&.arguments).should eq [%({"repo_ref":#{repo_ref.to_json}})]
      end
    end
  end

  it "update existing shard" do
    repo_ref = Repo::Ref.new("git", "mock://example.com/git/test.git")

    service = Service::ImportShard.new(repo_ref)

    transaction do |db|
      shard_id = Factory.create_shard(db, "test", description: "foo description")
      repo_id = Factory.create_repo(db, repo_ref, shard_id)

      shard_id = service.import_shard(db,
        Repo::Resolver.new(mock_resolver, repo_ref),
        Catalog::Entry.new(repo_ref, description: "bar description")
      )

      persisted_shards(db).should eq [{"test", "", "bar description"}]
      persisted_repos(db).should eq [{"git", "mock://example.com/git/test.git", "canonical", "test"}]

      find_queued_tasks("Service::SyncRepo").map(&.arguments).should eq [%({"repo_ref":{"resolver":"git","url":"mock://example.com/git/test.git"}})]

      repo_id = db.get_repo(repo_ref).id
      db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
        {"update_shard:description_changed", nil, shard_id, {
          "old_value" => "foo description",
        }},
      ]
    end
  end

  it "skips existing repo" do
    repo_ref = Repo::Ref.new("git", "mock://example.com/git/test.git")

    service = Service::ImportShard.new(repo_ref)

    transaction do |db|
      repo_id = Factory.create_repo(db, repo_ref, nil)

      shard_id = service.import_shard(db, Repo::Resolver.new(mock_resolver, repo_ref))

      persisted_shards(db).should eq [{"test", "", nil}]
      persisted_repos(db).should eq [{"git", "mock://example.com/git/test.git", "canonical", "test"}]

      find_queued_tasks("Service::SyncRepo").map(&.arguments).should eq [%({"repo_ref":{"resolver":"git","url":"mock://example.com/git/test.git"}})]

      db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
        {"import_shard:created", repo_id, shard_id, nil},
      ]
    end
  end

  it "handles unresolvable repo" do
    repo_ref = Repo::Ref.new("git", "mock://example.com/git/test.git")
    service = Service::ImportShard.new(repo_ref)

    transaction do |db|
      resolver = Repo::Resolver.new(MockResolver.unresolvable, repo_ref)
      service.import_shard(db, resolver)
    end
  end
end
