require "spec"
require "../../src/service/update_owner_metrics"
require "../support/db"
require "../support/factory"
require "../support/raven"

module Factory
  def self.create_shard_with_release(db, name)
    shard_id = create_shard(db, name)
    create_release(db, shard_id, latest: true)
  end

  def self.create_owner(db, name)
    db.create_owner(Repo::Owner.new("github", name))
  end

  def self.add_dependencies(db, shard, deps, scope = Dependency::Scope::RUNTIME)
    shard_id = db.get_shard_id(shard)
    deps.each do |dep|
      db.connection.exec <<-SQL, shard_id, dep, scope
        INSERT INTO shard_dependencies
        SELECT
          $1 AS shard_id,
          (
            SELECT
              id
            FROM shards
            WHERE name = $2
          ) AS depends_on,
          (
            SELECT
              repos.id
            FROM repos
            JOIN shards
              ON shards.id = repos.shard_id
              AND repos.role = 'canonical'
            WHERE name = $2
          ) AS depends_on_repo_id,
          $3 AS scope
        SQL
    end
  end

  def self.set_owner(db, owner_id, repo_ids)
    repo_ids.each do |repo_id|
      db.connection.exec <<-SQL, owner_id, repo_id
        UPDATE repos
        SET
          owner_id = $1
        WHERE
          id = $2
        SQL
    end
  end
end

describe Service::UpdateOwnerMetrics do
  it "calcs owner dependents" do
    transaction do |db|
      myshard1_id = Factory.create_shard db, "myshard1"
      myshard1_repo_id = Factory.create_repo db, Repo::Ref.new("github", "me/myshard1"), myshard1_id
      myshard2_id = Factory.create_shard db, "myshard2"
      myshard2_repo_id = Factory.create_repo db, Repo::Ref.new("github", "me/myshard2"), myshard2_id

      depshard1_id = Factory.create_shard db, "depshard1"
      depshard1_repo_id = Factory.create_repo db, Repo::Ref.new("github", "other/depshard1"), depshard1_id
      depshard2_id = Factory.create_shard db, "depshard2"
      depdepshard_id = Factory.create_shard db, "depdepshard"
      depdepshard_repo_id = Factory.create_repo db, Repo::Ref.new("github", "foo/depdepshard"), depdepshard_id

      Factory.add_dependencies(db, "depshard1", ["myshard1", "myshard2"])
      Factory.add_dependencies(db, "depshard2", ["myshard2"])
      Factory.add_dependencies(db, "depdepshard", ["depshard1"])

      owner_id = Factory.create_owner(db, "me")
      Factory.set_owner(db, owner_id, [myshard1_repo_id, myshard2_repo_id])

      service = Service::UpdateOwnerMetrics.new
      service.perform(db)

      results = db.connection.query_all <<-SQL, as: {Int64, Int32, Int32, Int32, Int32, Int32, Int32, Int32}
        SELECT
          owner_id,
          shards_count,
          dependents_count,
          transitive_dependents_count,
          dev_dependents_count,
          dependencies_count,
          transitive_dependencies_count,
          dev_dependencies_count
        FROM
          owner_metrics
        SQL
      results.should eq [{owner_id, 2, 2, 3, 0, 0, 0, 0}]

      results = db.connection.query_all <<-SQL, as: {Int64, Int32, Int32, Int32, Int32, Int32, Int32, Int32}
        SELECT
          id,
          shards_count,
          dependents_count,
          transitive_dependents_count,
          dev_dependents_count,
          dependencies_count,
          transitive_dependencies_count,
          dev_dependencies_count
        FROM
          owners
        SQL
      results.should eq [{owner_id, 2, 2, 3, 0, 0, 0, 0}]
    end
  end
end
