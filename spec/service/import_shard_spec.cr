require "spec"
require "../../src/service/import_shard"
require "../../src/catalog"
require "../support/raven"
require "../support/db"
require "../support/mock_resolver"

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

    transaction do |db|
      repo_id = Factory.create_repo(db, repo_ref, nil)

      shard_id = Service::ImportShard.new(db,
        db.get_repo(repo_id),
        entry: Catalog::Entry.new(repo_ref, description: "foo description"),
        resolver: Repo::Resolver.new(mock_resolver, repo_ref),
      ).perform

      ShardsDBHelper.persisted_shards(db).should eq [{"test", "", "foo description"}]

      repo_id = db.get_repo(repo_ref).id
      db.repos_pending_sync.map(&.ref).should eq [repo_ref]

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

    transaction do |db|
      repo_id = Factory.create_repo(db, repo_ref, nil)

      shard_id = Service::ImportShard.new(db,
        db.get_repo(repo_id),
        resolver: Repo::Resolver.new(mock_resolver, repo_ref),
      ).perform

      ShardsDBHelper.persisted_shards(db).should eq [{"test", "", nil}]

      db.repos_pending_sync.map(&.ref).should eq [repo_ref]

      db.last_activities.map { |a| {a.event, a.repo_id, a.shard_id, a.metadata} }.should eq [
        {"import_shard:created", repo_id, shard_id, nil},
      ]
    end
  end
end
