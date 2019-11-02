require "../catalog"
require "./import_shard"
require "./update_shard"
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

    category_stats = update_categories(db, categories)

    update_categorizations(db, repos)
    delete_obsolete_categorizations(db, repos)

    import_repos(db, repos)

    db.log_activity "import_catalog:done", metadata: category_stats
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

    ids = db.connection.build <<-SQL
      SELECT
        id, shard_id
      FROM
        repos
      WHERE
        resolver = $1 AND url = $2
      SQL

    all_repo_refs = [] of Repo::Ref

    entries.each do |entry|
      # 1. Insert canonical repo
      canonical_statement.exec(entry.repo_ref.resolver, entry.repo_ref.url)

      all_repo_refs << entry.repo_ref
      entry.mirrors.each do |mirror|
        all_repo_refs << mirror.repo_ref
      end

      # 2. Query id of canonical repo
      result = ids.query(entry.repo_ref.resolver, entry.repo_ref.url)
      unless result.move_next
        result.close
        next
      end

      repo_id, shard_id = result.read Int64, Int64?
      result.close

      # 3. If shard_id exists, update shard, otherwise create a new one
      if shard_id
        update_shard(db, entry, shard_id)
      else
        shard_id = create_shard(db, entry, repo_id)

        # If a shard could not be created, simply skip this one. The reason should
        # already be logged by ImportShard service.
        next unless shard_id
      end

      # 4. Insert mirror repos
      entry.mirrors.each do |item|
        mirror_statement.exec item.repo_ref.resolver, item.repo_ref.url, item.role, shard_id
      end
    end

    unlink_removed_repos(db, all_repo_refs)
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
    Service::ImportShard.new(entry.repo_ref).import_shard(db, repo_id, entry)
  end

  private def update_shard(db, entry, shard_id)
    Service::UpdateShard.new(shard_id, entry).perform(db)
  end

  private def unlink_removed_repos(db, valid_refs)
    resolvers = Array(String).new(valid_refs.size)
    urls = Array(String).new(valid_refs.size)
    valid_refs.each do |repo_ref|
      resolvers << repo_ref.resolver
      urls << repo_ref.url
    end

    # The following query is a bit complex.
    # It sets a repo to 'obsolete' state when it has been removed from the catalog.
    # If any of the following conditions is met, the repo is not obsolete:
    # 1) It's mentioned as canonical or mirror repo in the catalog (
    #    these are all collected in `valid_refs`)
    # 2) The referenced shard has no categories. Those repos have been discoverd
    #    as recursive dependencies. They need to be categorized, not obsoleted.
    # 3) It does not reference a shard. The repo entry has probably just been
    #    inserted from a dependency and waits for sync. After that it would meet
    #    condition 2).

    db.connection.exec <<-SQL, resolvers, urls
      UPDATE
        repos
      SET
        role = 'obsolete',
        shard_id = NULL
      WHERE
        id IN
          (
            WITH valid_refs AS (
              SELECT *
              FROM
                unnest($1::repo_resolver[], $2::citext[]) AS valid_refs (resolver, url)
            )
            SELECT
              repos.id
            FROM
              repos
            LEFT JOIN
              valid_refs v ON v.resolver = repos.resolver AND v.url = repos.url
            JOIN
              shards ON repos.shard_id = shards.id
            WHERE
              v.resolver IS NULL AND array_length(shards.categories, 1) > 0
          )
      SQL
  end

  def read_catalog
    categories = Hash(String, Category).new
    repos = {} of Repo::Ref => Catalog::Entry

    Catalog.each_category(@catalog_location) do |yaml_category, slug|
      category = Category.new(slug, yaml_category.name, yaml_category.description)
      categories[category.slug] = category
      yaml_category.shards.each do |shard|
        if stored_entry = repos[shard.repo_ref]?
          stored_entry.mirrors.concat(shard.mirrors)
          stored_entry.categories << slug
        else
          shard.categories << slug
          repos[shard.repo_ref] = shard
        end
      end
    end

    return categories, repos.values
  end

  def update_categories(db, categories)
    all_categories = db.connection.query_all <<-SQL, categories.keys, as: {String?, String?, String?, String?}
      SELECT
        categories.slug::text, target_categories.slug, name::text, description
      FROM
        categories
      FULL OUTER JOIN
        (
          SELECT unnest($1::text[]) AS slug
        ) AS target_categories
        ON categories.slug = target_categories.slug
      SQL

    deleted_categories = [] of String
    new_categories = [] of String
    updated_categories = [] of String
    all_categories.each do |existing_slug, new_slug, name, description|
      if existing_slug.nil?
        category = categories[new_slug]
        db.create_category(category)
        new_categories << new_slug.not_nil!
      elsif new_slug.nil?
        db.remove_category(existing_slug.not_nil!)
        deleted_categories << existing_slug.not_nil!
      else
        category = categories[existing_slug]
        if category.name != name || category.description != description
          db.update_category(category)
          updated_categories << category.slug
        end
      end
    end

    {
      "deleted_categories" => deleted_categories,
      "new_categories"     => new_categories,
      "updated_categories" => updated_categories,
    }
  end

  def update_categorizations(db, repos)
    repos.each do |entry|
      db.update_categorization(entry.repo_ref, entry.categories)
    end
  end

  def delete_obsolete_categorizations(db, repos)
    db.delete_categorizations(repos.map &.repo_ref)
  end

  def self.checkout_catalog(uri)
    checkout_catalog(uri, "./catalog")
  end

  def self.checkout_catalog(uri, checkout_path)
    if File.directory?(checkout_path)
      if Process.run("git", ["-C", checkout_path.to_s, "pull", uri.to_s], output: :inherit, error: :inherit).success?
        return checkout_path.to_s
      else
        abort "Can't checkout catalog from #{uri}: checkout path #{checkout_path.inspect} exists, but is not a git repository"
      end
    end

    Process.run("git", ["clone", uri.to_s, checkout_path.to_s], output: :inherit, error: :inherit)

    Path[checkout_path, "catalog"].to_s
  end
end
