require "../catalog"
require "./import_shard"
require "taskmaster"

struct Service::ImportCatalog
  include Taskmaster::Job

  def initialize(@catalog_location : String)
  end

  def perform
    ShardsDB.transaction do |db|
      import_catalog(db)
    end
  end

  def import_catalog(db)
    categories, repos = read_catalog

    create_or_update_categories(db, categories)
    delete_obsolete_categories(db, categories)

    update_categorizations(db, repos)
    delete_obsolete_categorizations(db, repos)

    import_repos(db, repos)
  end

  def import_repos(db, entries)
    canonical_statement = db.connection.build(<<-SQL)
      INSERT INTO repos
        (resolver, url, role)
      VALUES
        ($1, $2, 'canonical')
      ON CONFLICT ON CONSTRAINT repos_url_uniq DO UPDATE
      SET
        role = 'canonical',
        shard_id = NULL
      WHERE
        repos.role <> 'canonical'
      SQL

    mirrors = [] of Repo::Ref

    # 1. Insert all canonical repos
    entries.each do |entry|
      canonical_statement.exec(entry.repo_ref.resolver, entry.repo_ref.url)

      mirrors.concat(entry.mirror)
      mirrors.concat(entry.legacy)
    end

    mirror_statement = db.connection.build(<<-SQL)
      INSERT INTO repos
        (resolver, url, role, shard_id)
      VALUES
        ($1, $2, $3, $4)
      ON CONFLICT ON CONSTRAINT repos_url_uniq DO UPDATE
      SET
        role = $3,
        shard_id = $4
      WHERE repos.role <> $3 OR repos.shard_id <> $4
      SQL

    # 2. Query ids for all canonical repos
    ids = db.connection.build <<-SQL
      SELECT
        id, shard_id
      FROM
        repos
      WHERE
        resolver = $1 AND url = $2
      SQL

    entries.each do |entry|
      result = ids.query(entry.repo_ref.resolver, entry.repo_ref.url)
      unless result.move_next
        result.close
        next
      end

      repo_id, shard_id = result.read Int64, Int64?
      result.close

      unless shard_id
        shard_id = create_shard(db, entry, repo_id)

        # If a shard could not be created, simply skip this one. The reason should
        # already be logged by ImportShard service.
        next unless shard_id
      end

      entry.mirror.each do |item|
        mirror_statement.exec item.resolver, item.url, "mirror", shard_id
      end
      entry.legacy.each do |item|
        mirror_statement.exec item.resolver, item.url, "legacy", shard_id
      end
    end

    obsolete_deleted_repos(db, true, entries.map &.repo_ref)
    obsolete_deleted_repos(db, false, mirrors)
    delete_unreferenced_shards(db)
  end

  def delete_unreferenced_shards(db)
    db.connection.exec <<-SQL
      DELETE FROM
        shards
      WHERE NOT EXISTS (
        SELECT 1
        FROM
          repos
        WHERE shard_id = shards.id
        )
      SQL
  end

  private def create_shard(db, entry, repo_id)
    Service::ImportShard.new(entry.repo_ref).import_shard(db, repo_id)
  end

  private def obsolete_deleted_repos(db, canonical, valid_refs)
    if valid_refs.empty?
      # no mirror repos, delete all non-canonical
      db.connection.exec <<-SQL % (canonical ? "=" : "<>"),
        UPDATE
          repos
        SET
          role = 'obsolete',
          shard_id = NULL
        WHERE
          role %s 'canonical'
        SQL
    else
      args = [] of String
      sql_rows = Array(String).new(valid_refs.size)
      valid_refs.each_with_index do |repo_ref, index|
        args << repo_ref.resolver
        args << repo_ref.url
        sql_rows << "($#{index * 2 + 1}::repo_resolver, $#{index * 2 + 2}::citext)"
      end
      sql_rows = sql_rows.join(',')
      db.connection.exec <<-SQL % {canonical ? "=" : "<>", sql_rows}, args
        UPDATE
          repos
        SET
          role = 'obsolete',
          shard_id = NULL
        WHERE
          role %s 'canonical' AND
          ROW(resolver, url) <> ALL(ARRAY[%s])
        SQL
    end
  end

  def read_catalog
    categories = Array(Category).new
    repos = {} of Repo::Ref => Catalog::Entry

    Catalog.each_category(@catalog_location) do |yaml_category, slug|
      category = Category.new(slug, yaml_category.name, yaml_category.description)
      categories << category
      yaml_category.shards.each do |shard|
        if stored_entry = repos[shard.repo_ref]?
          stored_entry.mirror.concat(shard.mirror)
          stored_entry.legacy.concat(shard.legacy)
          stored_entry.categories << slug
        else
          shard.categories << slug
          repos[shard.repo_ref] = shard
        end
      end
    end

    return categories, repos.values
  end

  def create_or_update_categories(db, categories)
    categories.each do |category|
      db.create_or_update_category(category)
    end
  end

  def delete_obsolete_categories(db, categories)
    db.remove_categories(categories.map(&.slug))
  end

  def update_categorizations(db, repos)
    repos.each do |entry|
      db.update_categorization(entry.repo_ref, entry.categories)
    end
  end

  def delete_obsolete_categorizations(db, repos)
    db.delete_categorizations(repos.map &.repo_ref)
  end
end
