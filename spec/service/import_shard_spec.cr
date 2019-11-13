require "spec"
require "../support/raven"
require "../../src/service/import_shard"
require "../../src/catalog"
require "../support/db"
require "../support/jobs"
require "../support/mock_resolver"

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

  it "creates new shard" do
    repo_ref = Repo::Ref.new("git", "mock:test")
    service = Service::ImportShard.new(repo_ref)

    transaction do |db|
      repo_id = Factory.create_repo(db, repo_ref, nil)

      shard_id = service.import_shard(db,
        entry: Catalog::Entry.new(repo_ref, description: "foo description"),
        resolver: Repo::Resolver.new(mock_resolver, repo_ref),
      )

      ShardsDBHelper.persisted_shards(db).should eq [{"test", "", "foo description"}]
      persisted_repos(db).should eq [{"git", "mock:test", "canonical", "test"}]

      repo_id = db.get_repo(repo_ref).id
      find_queued_tasks("Service::SyncRepo").map(&.arguments).should eq [%({"repo_ref":#{repo_ref.to_json}})]

      shard_categorizations(db).should eq [
        {"test", "", nil},
      ]

      db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
        {"import_shard:created", repo_id, shard_id, nil},
      ]
    end
  end

  it "uses existing repo" do
    repo_ref = Repo::Ref.new("git", "mock://example.com/git/test.git")

    service = Service::ImportShard.new(repo_ref)

    transaction do |db|
      repo_id = Factory.create_repo(db, repo_ref, nil)

      shard_id = service.import_shard(db,
        resolver: Repo::Resolver.new(mock_resolver, repo_ref))

      ShardsDBHelper.persisted_shards(db).should eq [{"test", "", nil}]
      persisted_repos(db).should eq [{"git", "mock://example.com/git/test.git", "canonical", "test"}]

      find_queued_tasks("Service::SyncRepo").map(&.arguments).should eq [%({"repo_ref":{"resolver":"git","url":"mock://example.com/git/test.git"}})]

      db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
        {"import_shard:created", repo_id, shard_id, nil},
      ]
    end
  end

  pending "handles unresolvable repo" do
    repo_ref = Repo::Ref.new("git", "mock://example.com/git/test.git")
    service = Service::ImportShard.new(repo_ref)

    transaction do |db|
      resolver = Repo::Resolver.new(MockResolver.unresolvable, repo_ref)
      service.import_shard(db, resolver)
    end
  end
end
