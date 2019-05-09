require "spec"
require "../../src/service/update_dependencies"
require "../support/db"
require "../support/factory"
require "../support/raven"

private def persisted_dependencies(db)
  db.connection.query_all <<-SQL, as: {Int64, Int64, String}
        SELECT
          shard_id, depends_on, scope::text
        FROM
          shard_dependencies
        ORDER BY
          shard_id, depends_on
        SQL
end

private def dependents_stats(db)
  db.connection.query_all <<-SQL, as: {Int64, Int32?, Int32?, Int32?}
    WITH max_ids AS (
      SELECT
        MAX(id) AS id
      FROM
        shard_metrics
      GROUP BY
        shard_id
    )
    SELECT
      shard_id, dependents_count, dev_dependents_count, transitive_dependents_count
    FROM
      shard_metrics
    JOIN
      max_ids USING(id)
    WHERE
      dependents_count > 0 OR dev_dependents_count > 0 OR transitive_dependents_count > 0
    ORDER BY
      id
    SQL
end

private def dependencies_stats(db)
  db.connection.query_all <<-SQL, as: {Int64, Int32?, Int32?, Int32?}
    WITH max_ids AS (
      SELECT
        MAX(id) AS id
      FROM
        shard_metrics
      GROUP BY
        shard_id
    )
    SELECT
      shard_id, dependencies_count, dev_dependencies_count, transitive_dependencies_count
    FROM
      shard_metrics
    JOIN
      max_ids USING(id)
    WHERE
      dependencies_count > 0 OR dev_dependencies_count > 0 OR transitive_dependencies_count > 0
    ORDER BY
      shard_id
    SQL
end

def calculate_shard_metrics(db)
  ids = db.connection.query_all <<-SQL, as: Int64
    SELECT
      id
    FROM
      shards
    SQL
  ids.each do |id|
    db.connection.exec "SELECT shard_metrics_calculate($1)", id
  end
end

describe Service::UpdateDependencies do
  it "calcs shard dependencies" do
    transaction do |db|
      db.connection.on_notice do |notice|
        puts notice
      end
      foo_id = Factory.create_shard(db, "foo")
      foo_release1 = Factory.create_release(db, foo_id, "0.1.0")
      foo_release2 = Factory.create_release(db, foo_id, "0.2.0", latest: true)
      foo_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "foo"), shard_id: foo_id)
      foo_repo_id2 = Factory.create_repo(db, Repo::Ref.new("git", "foo2"), shard_id: foo_id, role: :mirror)
      bar_id = Factory.create_shard(db, "bar")
      bar_release2 = Factory.create_release(db, bar_id, "0.2.0", latest: true)
      bar_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "bar"), shard_id: bar_id)
      baz_id = Factory.create_shard(db, "baz")
      baz_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "baz"), shard_id: baz_id)
      baz_release2 = Factory.create_release(db, baz_id, "0.2.0", latest: true)
      qux_id = Factory.create_shard(db, "qux")
      qux_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "qux"), shard_id: qux_id)
      missing_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "missing"), shard_id: nil)

      service = Service::UpdateDependencies.new
      # dependencies
      Factory.create_dependency(db, foo_release2, "baz", repo_id: baz_repo_id)
      Factory.create_dependency(db, foo_release2, "missing", repo_id: missing_repo_id)

      service.update_shard_dependencies(db)
      persisted_dependencies(db).should eq [
        {foo_id, baz_id, "runtime"},
      ]

      calculate_shard_metrics(db)
      dependents_stats(db).should eq [
        {baz_id, 1, 0, 1},
      ]
      dependencies_stats(db).should eq [
        {foo_id, 2, 0, 2},
      ]

      Factory.create_dependency(db, foo_release1, "bar", repo_id: baz_repo_id)

      service.update_shard_dependencies(db)
      persisted_dependencies(db).should eq [
        {foo_id, baz_id, "runtime"},
      ]

      calculate_shard_metrics(db)
      dependents_stats(db).should eq [
        {baz_id, 1, 0, 1},
      ]
      dependencies_stats(db).should eq [
        {foo_id, 2, 0, 2},
      ]

      Factory.create_dependency(db, foo_release2, "bar", repo_id: bar_repo_id)

      service.update_shard_dependencies(db)
      persisted_dependencies(db).should eq [
        {foo_id, bar_id, "runtime"},
        {foo_id, baz_id, "runtime"},
      ]

      calculate_shard_metrics(db)
      dependents_stats(db).should eq [
        {bar_id, 1, 0, 1},
        {baz_id, 1, 0, 1},
      ]
      dependencies_stats(db).should eq [
        {foo_id, 3, 0, 3},
      ]

      Factory.create_dependency(db, bar_release2, "qux", repo_id: qux_repo_id)
      Factory.create_dependency(db, bar_release2, "baz", repo_id: baz_repo_id)
      Factory.create_dependency(db, baz_release2, "qux", repo_id: qux_repo_id, scope: "development")

      service.update_shard_dependencies(db)
      persisted_dependencies(db).should eq [
        {foo_id, bar_id, "runtime"},
        {foo_id, baz_id, "runtime"},
        {bar_id, baz_id, "runtime"},
        {bar_id, qux_id, "runtime"},
        {baz_id, qux_id, "development"},
      ]

      calculate_shard_metrics(db)
      dependents_stats(db).should eq [
        {bar_id, 1, 0, 1},
        {baz_id, 2, 0, 2},
        {qux_id, 1, 1, 2},
      ]
      dependencies_stats(db).should eq [
        {foo_id, 3, 0, 4},
        {bar_id, 2, 0, 2},
        {baz_id, 0, 1, 0},
      ]

      db.connection.exec <<-SQL, foo_release2
        DELETE FROM dependencies
        WHERE
          release_id = $1 AND name = 'bar'
        SQL

      service.update_shard_dependencies(db)
      persisted_dependencies(db).should eq [
        {foo_id, baz_id, "runtime"},
        {bar_id, baz_id, "runtime"},
        {bar_id, qux_id, "runtime"},
        {baz_id, qux_id, "development"},
      ]

      calculate_shard_metrics(db)
      dependents_stats(db).should eq [
        {baz_id, 2, 0, 2},
        {qux_id, 1, 1, 1},
      ]
      dependencies_stats(db).should eq [
        {foo_id, 2, 0, 2},
        {bar_id, 2, 0, 2},
        {baz_id, 0, 1, 0},
      ]
    end
  end
end
