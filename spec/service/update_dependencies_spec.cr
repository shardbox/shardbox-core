require "spec"
require "../../src/service/sync_repos"
require "../support/db"
require "../support/factory"
require "../support/raven"

private def persisted_dependencies(db)
  db.connection.query_all <<-SQL, as: {Int64, Int64?, Int64, String}
        SELECT
          shard_id, depends_on, depends_on_repo_id, scope::text
        FROM
          shard_dependencies
        ORDER BY
          shard_id, depends_on
        SQL
end

private def dependents_stats(db)
  db.connection.query_all <<-SQL, as: {Int64, Int32?, Int32?, Int32?}
    SELECT
      shard_id, dependents_count, dev_dependents_count, transitive_dependents_count
    FROM
      shard_metrics_current
    WHERE
      dependents_count > 0 OR dev_dependents_count > 0 OR transitive_dependents_count > 0
    ORDER BY
      id
    SQL
end

private def dependencies_stats(db)
  db.connection.query_all <<-SQL, as: {Int64, Int32?, Int32?, Int32?}
    SELECT
      shard_id, dependencies_count, dev_dependencies_count, transitive_dependencies_count
    FROM
      shard_metrics_current
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

describe "Service::SyncRepos #update_shard_dependencies" do
  it "calcs shard dependencies" do
    transaction do |db|
      foo_id = Factory.create_shard(db, "foo")
      Factory.create_repo(db, Repo::Ref.new("git", "foo"), shard_id: foo_id)
      foo_release = Factory.create_release(db, foo_id, "0.0.0", latest: true)
      bar_id = Factory.create_shard(db, "bar")
      bar_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "bar"), shard_id: bar_id)

      Factory.create_dependency(db, foo_release, "bar", repo_id: bar_repo_id)

      service = Service::SyncRepos.new(db)

      service.update_shard_dependencies

      persisted_dependencies(db).should eq [
        {foo_id, bar_id, bar_repo_id, "runtime"},
      ]

      calculate_shard_metrics(db)

      dependents_stats(db).should eq [
        {bar_id, 1, 0, 1},
      ]
      dependencies_stats(db).should eq [
        {foo_id, 1, 0, 1},
      ]
    end
  end

  it "calcs shard dev dependencies" do
    transaction do |db|
      foo_id = Factory.create_shard(db, "foo")
      Factory.create_repo(db, Repo::Ref.new("git", "foo"), shard_id: foo_id)
      foo_release = Factory.create_release(db, foo_id, "0.0.0", latest: true)
      bar_id = Factory.create_shard(db, "bar")
      bar_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "bar"), shard_id: bar_id)

      Factory.create_dependency(db, foo_release, "bar", repo_id: bar_repo_id, scope: "development")

      service = Service::SyncRepos.new(db)

      service.update_shard_dependencies

      persisted_dependencies(db).should eq [
        {foo_id, bar_id, bar_repo_id, "development"},
      ]

      calculate_shard_metrics(db)

      dependents_stats(db).should eq [
        {bar_id, 0, 1, 0},
      ]
      dependencies_stats(db).should eq [
        {foo_id, 0, 1, 0},
      ]
    end
  end

  it "calcs shard dependencies with missing repo" do
    transaction do |db|
      foo_id = Factory.create_shard(db, "foo")
      Factory.create_repo(db, Repo::Ref.new("git", "foo"), shard_id: foo_id)
      foo_release = Factory.create_release(db, foo_id, "0.0.0", latest: true)
      missing_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "missing"), shard_id: nil)

      Factory.create_dependency(db, foo_release, "missing", repo_id: missing_repo_id)

      service = Service::SyncRepos.new(db)

      service.update_shard_dependencies

      persisted_dependencies(db).should eq [
        {foo_id, nil, missing_repo_id, "runtime"},
      ]

      calculate_shard_metrics(db)

      dependents_stats(db).should be_empty

      dependencies_stats(db).should eq [
        {foo_id, 1, 0, 1},
      ]
    end
  end

  it "calcs shard dependencies with existing and missing repo" do
    transaction do |db|
      foo_id = Factory.create_shard(db, "foo")
      Factory.create_repo(db, Repo::Ref.new("git", "foo"), shard_id: foo_id)
      foo_release = Factory.create_release(db, foo_id, "0.0.0", latest: true)
      missing_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "missing"), shard_id: nil)
      bar_id = Factory.create_shard(db, "bar")
      bar_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "bar"), shard_id: bar_id)

      Factory.create_dependency(db, foo_release, "missing", repo_id: missing_repo_id)
      Factory.create_dependency(db, foo_release, "bar", repo_id: bar_repo_id)

      service = Service::SyncRepos.new(db)

      service.update_shard_dependencies

      persisted_dependencies(db).should eq [
        {foo_id, bar_id, bar_repo_id, "runtime"},
        {foo_id, nil, missing_repo_id, "runtime"},
      ]

      calculate_shard_metrics(db)

      dependents_stats(db).should eq [
        {bar_id, 1, 0, 1},
      ]

      dependencies_stats(db).should eq [
        {foo_id, 2, 0, 2},
      ]
    end
  end

  it "calcs shard dependencies with multiple releases" do
    transaction do |db|
      foo_id = Factory.create_shard(db, "foo")
      Factory.create_repo(db, Repo::Ref.new("git", "foo"), shard_id: foo_id)
      foo_release1 = Factory.create_release(db, foo_id, "0.1.0")
      foo_release2 = Factory.create_release(db, foo_id, "0.2.0", latest: true)
      bar_id = Factory.create_shard(db, "bar")
      bar_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "bar"), shard_id: bar_id)

      Factory.create_dependency(db, foo_release1, "bar", repo_id: bar_repo_id)
      Factory.create_dependency(db, foo_release2, "bar", repo_id: bar_repo_id)

      service = Service::SyncRepos.new(db)

      service.update_shard_dependencies

      persisted_dependencies(db).should eq [
        {foo_id, bar_id, bar_repo_id, "runtime"},
      ]

      calculate_shard_metrics(db)

      dependents_stats(db).should eq [
        {bar_id, 1, 0, 1},
      ]

      dependencies_stats(db).should eq [
        {foo_id, 1, 0, 1},
      ]
    end
  end

  it "calcs shard dependencies transitive" do
    transaction do |db|
      foo_id = Factory.create_shard(db, "foo")
      foo_release = Factory.create_release(db, foo_id, "0.1.0", latest: true)
      foo_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "foo"), shard_id: foo_id)
      bar_id = Factory.create_shard(db, "bar")
      bar_release = Factory.create_release(db, bar_id, "0.1.0", latest: true)
      bar_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "bar"), shard_id: bar_id)
      baz_id = Factory.create_shard(db, "baz")
      baz_release = Factory.create_release(db, baz_id, "0.1.0", latest: true)
      baz_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "baz"), shard_id: baz_id)
      qux_id = Factory.create_shard(db, "qux")
      qux_repo_id = Factory.create_repo(db, Repo::Ref.new("git", "qux"), shard_id: qux_id)

      service = Service::SyncRepos.new(db)

      Factory.create_dependency(db, foo_release, "baz", repo_id: baz_repo_id)
      Factory.create_dependency(db, foo_release, "bar", repo_id: bar_repo_id)
      Factory.create_dependency(db, baz_release, "qux", repo_id: qux_repo_id)
      Factory.create_dependency(db, bar_release, "baz", repo_id: baz_repo_id)

      service.update_shard_dependencies

      persisted_dependencies(db).should eq [
        {foo_id, bar_id, bar_repo_id, "runtime"},
        {foo_id, baz_id, baz_repo_id, "runtime"},
        {bar_id, baz_id, baz_repo_id, "runtime"},
        {baz_id, qux_id, qux_repo_id, "runtime"},
      ]

      calculate_shard_metrics(db)

      dependents_stats(db).should eq [
        {bar_id, 1, 0, 1},
        {baz_id, 2, 0, 2},
        {qux_id, 1, 0, 3},
      ]
      dependencies_stats(db).should eq [
        {foo_id, 2, 0, 3},
        {bar_id, 1, 0, 2},
        {baz_id, 1, 0, 1},
      ]
    end
  end
end
