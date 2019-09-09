require "db"
require "pg"
require "./shard"
require "./release"
require "./category"
require "./repo"

class ShardsDB
  class Error < Exception
  end

  class_property database_url : String { ENV["DATABASE_URL"] }

  @@db : DB::Database?

  def self.db
    @@db ||= DB.open(database_url)
  end

  # :nodoc:
  def self.db?
    @@db
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

  def last_repo_sync : Time?
    connection.query_one?("SELECT MAX(created_at) FROM sync_log", as: Time)
  end

  def last_metrics_calc : Time?
    connection.query_one?("SELECT MAX(created_at) FROM shard_metrics_current", as: Time)
  end

  def find_shard_id?(name : String)
    connection.query_one? <<-SQL, name, as: {Int64}
      SELECT id
      FROM shards
      WHERE
        name = $1
      LIMIT 1
      SQL
  end

  def get_repo_shard_id(resolver : String, url : String)
    connection.query_one <<-SQL, resolver, url, as: Int64
          SELECT
            shard_id
          FROM
            repos
          WHERE
            resolver = $1 AND url = $2
          SQL
  end

  def get_repo_shard_id?(resolver : String, url : String)
    connection.query_one? <<-SQL, resolver, url, as: Int64
          SELECT
            shard_id
          FROM
            repos
          WHERE
            resolver = $1 AND url = $2
          SQL
  end

  def find_canonical_repo(shard_id : Int64)
    resolver, url, metadata, synced_at = connection.query_one <<-SQL, shard_id, as: {String, String, String, Time?}
      SELECT resolver::text, url::text, metadata::text, synced_at
      FROM repos
      WHERE
        shard_id = $1 AND role = 'canonical'
      SQL

    Repo.new(resolver, url, shard_id, "canonical", Repo::Metadata.from_json(metadata), synced_at)
  end

  def find_repo(repo_ref : Repo::Ref)
    result = connection.query_one <<-SQL, repo_ref.resolver, repo_ref.url, as: {Int64, Int64?, String, String, Time?, Time?}
      SELECT
        id, shard_id, role::text, metadata::text, synced_at, sync_failed_at
      FROM
        repos
      WHERE
        resolver = $1 AND url = $2
      SQL

    id, shard_id, role, metadata, synced_at, sync_failed_at = result
    Repo.new(repo_ref, shard_id, Repo::Role.parse(role), Repo::Metadata.from_json(metadata), synced_at, sync_failed_at, id: id)
  end

  def find_repo?(repo_ref : Repo::Ref)
    result = connection.query_one? <<-SQL, repo_ref.resolver, repo_ref.url, as: {Int64, Int64?, String, String, Time?, Time?}
      SELECT
        id, shard_id, role::text, metadata::text, synced_at, sync_failed_at
      FROM
        repos
      WHERE
        resolver = $1 AND url = $2
      SQL

    return unless result

    id, shard_id, role, metadata, synced_at, sync_failed_at = result
    Repo.new(repo_ref, shard_id, Repo::Role.parse(role), Repo::Metadata.from_json(metadata), synced_at, sync_failed_at, id: id)
  end

  def find_repo_ref(id : Int64)
    result = connection.query_one <<-SQL, id, as: {String, String}
      SELECT
        resolver::text, url::text
      FROM
        repos
      WHERE
        id = $1
      SQL

    Repo::Ref.new(*result)
  end

  def create_shard(shard : Shard)
    shard_id = connection.query_one <<-SQL, shard.name, shard.qualifier, shard.description, as: Int64
      INSERT INTO shards
        (name, qualifier, description)
      VALUES
        ($1, $2, $3)
      RETURNING id;
      SQL
  end

  def create_repo(repo : Repo)
    connection.query_one <<-SQL, repo.shard_id, repo.ref.resolver, repo.ref.url, repo.role, as: Int64
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

  def self.create_release(shard_id : Int64, release : Release, position = nil)
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
      as: {Int64}
  end

  def upsert_dependency(release_id : Int64, dependency : Dependency, repo_id = nil)
    connection.exec <<-SQL, release_id, repo_id, dependency.name, dependency.spec.to_json, dependency.scope
      INSERT INTO dependencies
        (release_id, repo_id, name, spec, scope)
      VALUES
        ($1, $2, $3, $4::jsonb, $5, $6)
      ON CONFLICT ON CONSTRAINT dependencies_uniq
      DO UPDATE SET
        repo_id = $2, spec = $4::jsonb, scope = $5
      SQL
  end

  def create_or_update_category(category : Category)
    category_id = connection.exec <<-SQL, category.slug, category.name, category.description
      INSERT INTO categories
        (slug, name, description)
      VALUES
        ($1, $2, $3)
      ON CONFLICT ON CONSTRAINT categories_slug_uniq
      DO UPDATE SET
        name = $2, description = $3
      SQL
  end

  def all_categories
    results = connection.query_all <<-SQL, as: {Int64, String, String, String?, Int32}
      SELECT
        id, slug::text, name::text, description::text, entries_count
      FROM
        categories
      ORDER BY
        name ASC
      SQL

    results.map do |result|
      id, slug, name, description, entries_count = result

      Category.new(slug, name, description, entries_count, id: id)
    end
  end

  def shards_in_category(category_id : Int64?)
    if category_id
      args = [category_id]
      where = "$1 = ANY(categories)"
    else
      args = [] of String
      where = "categories = '{}'::bigint[]"
    end

    results = connection.query_all <<-SQL, args, as: {Int64, String, String, String?, String, String}
      SELECT
        shards.id, name::text, qualifier::text, shards.description,
        repos.resolver::text, repos.url::text
      FROM
        shards
      JOIN
        repos ON repos.shard_id = shards.id AND repos.role = 'canonical'
      WHERE
        #{where}
      ORDER BY
        shards.name
      SQL

    results.map do |result|
      shard_id, name, qualifier, description, resolver, url = result

      {
        shard: Shard.new(name, qualifier, description, id: shard_id),
        repo:  Repo.new(resolver, url, shard_id),
      }
    end
  end

  def find_mirror_repos(shard_id : Int64)
    results = [] of Repo
    connection.query_all <<-SQL, shard_id do |result|
      SELECT resolver::text, url::text, role::text, metadata::text, synced_at
      FROM repos
      WHERE
        shard_id = $1 AND role <> 'canonical'
      ORDER BY
        role, url
      SQL
      resolver, url, role, metadata, synced_at = result.read String, String, String, String, Time?
      results << Repo.new(resolver, url, shard_id, role, Repo::Metadata.from_json(metadata), synced_at)
    end
    results
  end

  def remove_categories(category_slugs : Array(String))
    connection.exec <<-SQL % sql_array(category_slugs)
      DELETE FROM categories
      WHERE slug != ALL(ARRAY[%s]::text[])
      SQL
  end

  private def sql_array(array)
    String.build do |io|
      array.each_with_index do |category, i|
        io << ", " unless i == 0
        io << '\''
        io << category.gsub("'", "\\'")
        io << '\''
      end
    end
  end

  def update_categorization(repo_ref : Repo::Ref, categories : Array(String))
    sql = <<-SQL % sql_array(categories)
      UPDATE
        shards
      SET
        categories = coalesce((SELECT array_agg(id) FROM categories WHERE slug = ANY(ARRAY[%s]::text[])), ARRAY[]::bigint[])
      WHERE
        id = (SELECT shard_id FROM repos WHERE resolver = $1 AND url = $2)
      SQL
    connection.exec sql, repo_ref.resolver, repo_ref.url
  end

  def delete_categorizations(repo_refs : Array(Repo::Ref))
    # TODO: Implement
  end

  # LOGGING
  def sync_log(repo_id : Int64, event : String, metadata)
    connection.exec <<-SQL, repo_id, event, metadata.to_json
        INSERT INTO sync_log
        (
          repo_id, event, metadata
        )
        VALUES
        (
          $1, $2, $3
        )
      SQL
  end
end

at_exit do
  ShardsDB.db?.try &.close
end

<<-SQL
WITH shard_dependencies AS  ( SELECT DISTINCT dependent_shard.name AS shard, shards.name AS depends_on FROM shards JOIN dependencies ON dependencies.shard _id = shards.id JOIN releases ON releases.id = dependencies.release_id JOIN shards AS dependent_shard ON dependent_shard.id = releases.shard_id ) SELECT shard, array_agg (depends_on), count(shard) FROM shard_dependencies GROUP BY shard;
SQL
<<-SQL
WITH shard_dependencies AS  ( SELECT DISTINCT dependent_shard.name AS shard, shards.name AS depends_on FROM shards JOIN dependencies ON dependencies.shard _id = shards.id JOIN releases ON releases.id = dependencies.release_id JOIN shards AS dependent_shard ON dependent_shard.id = releases.shard_id ) SELECT depends_on, arra y_agg(shard), count(depends_on) FROM shard_dependencies GROUP BY depends_on;
SQL
