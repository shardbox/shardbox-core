require "db"
require "pg"
require "./shard"
require "./release"

class ShardsDB
  class Error < Exception
  end

  class_property database_url : String { ENV["SHARDSDB_DATABASE"] }

  @@db : DB::Database?

  def self.db
    @@db ||= DB.open(database_url)
  end

  def self.connect
    db.using_connection do |connection|
      yield ShardsDB.new(connection)
    end
  end

  def self.transaction
    db.transaction do |transaction|
      yield ShardsDB.new(transaction.connection), transaction
    end
  end

  def initialize(@connection : DB::Connection)
  end

  getter connection

  def find_shard_id?(name : String)
    connection.query_one? <<-SQL, name, as: {Int32}
      SELECT id
      FROM shards
      WHERE
        name = $1
      LIMIT 1
      SQL
  end

  def find_canonical_repo(shard_id : Int32)
    resolver, url = connection.query_one <<-SQL, shard_id, as: {String, String}
      SELECT resolver::text, url::text
      FROM repos
      WHERE
        shard_id = $1 AND role = 'canonical'
      SQL

    Repo.new(shard_id, resolver, url, "canonical")
  end

  def create_shard(shard : Shard)
    shard_id = connection.query_one <<-SQL, shard.name, shard.qualifier, shard.description, as: {Int32}
      INSERT INTO shards
        (name, qualifier, description)
      VALUES
        ($1, $2, $3)
      RETURNING id;
      SQL
  end

  def create_repo(repo : Repo)
    connection.query_one? <<-SQL, repo.shard_id, repo.ref.resolver, repo.ref.url, repo.role, as: Int32
      INSERT INTO repos
        (shard_id, resolver, url, role)
      VALUES
        ($1, $2, $3, $4)
      RETURNING id
      SQL
  end

  def repo_exists?(repo_ref : Repo::Ref) : Bool
    result = connection.query_one? <<-SQL, repo_ref.resolver, repo_ref.url.to_s, as: Int32
      SELECT 1
      FROM repos
      WHERE
        resolver = $1 AND url = $2
      SQL
    !result.nil?
  end

  def self.create_release(shard_id : Int32, release : Release, position = nil)
    position_sql = position ? position.to_s : "(SELECT MAX(position) FROM releases WHERE shard_id = $1)"
    sql = <<-SQL
      INSERT INTO releases
        (shard_id, version, released_at, spec, revision_info, latest, yanked_at, position)
      VALUES
        ($1, $2, $3, $4, $5, $6, $7, #{position_sql})
      RETURNING id
      SQL
    connection.query_one sql,
      shard_id, release.version, release.released_at.at_beginning_of_second,
      release.spec, release.revision_info, release.latest? || nil,
      yanked_at.try(&.at_beginning_of_second),
      as: {Int32}
  end

  def upsert_dependency(release_id : Int32, dependency : Dependency, shard_id = nil)
    connection.exec <<-SQL, release_id, shard_id, dependency.name, dependency.spec.to_json, dependency.scope, dependency.resolvable?
      INSERT INTO dependencies
        (release_id, shard_id, name, spec, scope, resolvable)
      VALUES
        ($1, $2, $3, $4::jsonb, $5, $6)
      ON CONFLICT ON CONSTRAINT dependencies_uniq
      DO UPDATE SET
        shard_id = $2, spec = $4::jsonb, scope = $5
      SQL
  end
end

at_exit do
  ShardsDB.db.close
end

<<-SQL
WITH shard_dependencies AS  ( SELECT DISTINCT dependent_shard.name AS shard, shards.name AS depends_on FROM shards JOIN dependencies ON dependencies.shard _id = shards.id JOIN releases ON releases.id = dependencies.release_id JOIN shards AS dependent_shard ON dependent_shard.id = releases.shard_id ) SELECT shard, array_agg (depends_on), count(shard) FROM shard_dependencies GROUP BY shard;
SQL
<<-SQL
WITH shard_dependencies AS  ( SELECT DISTINCT dependent_shard.name AS shard, shards.name AS depends_on FROM shards JOIN dependencies ON dependencies.shard _id = shards.id JOIN releases ON releases.id = dependencies.release_id JOIN shards AS dependent_shard ON dependent_shard.id = releases.shard_id ) SELECT depends_on, arra y_agg(shard), count(depends_on) FROM shard_dependencies GROUP BY depends_on;
SQL
