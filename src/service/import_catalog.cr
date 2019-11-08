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
      import_stats = import_catalog(db)

      db.log_activity "import_catalog:done", metadata: import_stats
    end
  rescue exc
    begin
      ShardsDB.transaction do |db|
        db.log_activity "import_catalog:failed", metadata: {"exception" => exc.class.to_s}
      end
    rescue
    end

    raise exc
  end

  def import_catalog(db)
    categories, entries = Catalog.read(@catalog_location)

    category_stats = update_categories(db, categories)

    update_categorizations(db, entries)
    delete_obsolete_categorizations(db, entries)

    import_repos(db, entries)

    category_stats
  end

  def import_repos(db, entries)
    entries.each do |entry|
      import_repo(db, entry, entries)
    end

    obsolete_removed_repos(db, entries.map &.repo_ref)
    archive_unreferenced_shards(db)
  end

  def import_repo(db, entry, entries)
    repo_id, shard_id, role = db.connection.query_one?(<<-SQL, entry.repo_ref.resolver, entry.repo_ref.url, as: {Int64, Int64?, String}) || {nil, nil, nil}
      SELECT
        id, shard_id, role::text
      FROM
        repos
      WHERE
        resolver = $1 AND url = $2
      SQL

    if !shard_id
      # No shard associated with this repo
      if repo_id
        # Repo exists but has no shard associated.
        # It's either an obsolete repo or canonical waiting for shard creation.
        if role == "obsolete"
          db.log_activity "import_catalog:repo:reactivated", repo_id: repo_id
        end
      else
        # Repo does not yet exist, insert canonical repo
        repo = Repo.new(entry.repo_ref, nil, :canonical)
        repo_id = db.create_repo(repo)

        db.log_activity "import_catalog:repo:created", repo_id: repo_id
      end

      shard_id = create_shard(db, entry, repo_id)
    elsif role == "canonical"
      # We're not using Repo::Role here because `obsolete` is not a valid value
      # but may exist in the database.

      # Is already canonical repo, do update
      update_shard(db, entry, shard_id)
    else
      # Repo exists
      repo_id = repo_id.not_nil!
      # Is not canonical repo, need to check whether it's the same shard or a new one

      result = db.connection.query_one? <<-SQL, shard_id, as: {String, String}
        SELECT
          resolver::text, url::text
        FROM
          repos
        WHERE
          shard_id = $1 AND role = 'canonical'
        SQL
      if result
        # There is a canonical repo
        canonical_repo = Repo::Ref.new(*result)
        if mirror = entry.mirrors.find { |mirror| mirror.repo_ref == canonical_repo }
          # Same shard, switched canonical repo
          set_role(db, mirror.repo_ref, mirror.role)
          set_role(db, repo_id, "canonical")
          db.log_activity "import_catalog:shard:canonical_switched", repo_id: repo_id, shard_id: shard_id, metadata: {"old_repo" => mirror.repo_ref}
          update_shard(db, entry, shard_id)
        else
          canonical_entry = entries.find do |entry|
            entry.repo_ref == canonical_repo || entry.mirrors.find { |mirror| mirror.repo_ref == canonical_repo }
          end
          if canonical_entry
            # Separated old mirror to new shard
            shard_id = create_shard(db, entry, repo_id)
          else
            # Old canonical is removed. Taking over existing shard
            # NOTE: This should not happen. Old canonicals should usually be
            # listed as legacy in the catalog
            set_role(db, canonical_repo, "obsolete")
            set_role(db, repo_id, "canonical")
            db.log_activity "import_catalog:shard:canonical_switched", repo_id: repo_id, shard_id: shard_id, metadata: {"old_repo" => canonical_repo}
            update_shard(db, entry, shard_id)
            # send_notification("obsolete repo")
          end
        end
      else
        # There is no canonical repo, taking over
        set_role(db, repo_id, "canonical")
        update_shard(db, entry, shard_id)
      end
    end

    update_mirrors(db, entry, shard_id)
  end

  def set_role(db, repo_ref : Repo::Ref, role)
    db.connection.exec <<-SQL, repo_ref.resolver, repo_ref.url, role
      UPDATE repos
      SET
        role = $3
      WHERE
        resolver = $1 AND url = $2
      SQL
  end

  def set_role(db, repo_id : Int64, role)
    if role == "obsolete"
      db.connection.exec <<-SQL, repo_id, role
        UPDATE repos
        SET
          role = $2,
          shard_id = NULL
        WHERE
          repo_id = $1
        SQL
    else
      db.connection.exec <<-SQL, repo_id, role
        UPDATE repos
        SET
          role = $2
        WHERE
          repo_id = $1
        SQL
    end
  end

  def update_mirrors(db, entry, shard_id)
    db_mirrors = db.connection.query_all <<-SQL, shard_id, as: {String, String, String}
      SELECT
        resolver::text, url::text, role::text
      FROM
        repos
      WHERE
        shard_id = $1
      AND
        role <> 'canonical'
      SQL

    db_mirrors = db_mirrors.map do |resolver, url, role|
      Catalog::Mirror.new(Repo::Ref.new(resolver, url), Repo::Role.parse(role))
    end

    new_mirrors = entry.mirrors.reject do |mirror|
      db_mirrors.any? { |m| m.repo_ref == mirror.repo_ref }
    end

    removed_mirrors = db_mirrors.reject do |mirror|
      entry.mirrors.any? { |m| m.repo_ref == mirror.repo_ref }
    end

    updated_mirrors = db_mirrors.select do |mirror|
      entry.mirrors.any? { |m| m.repo_ref == mirror.repo_ref && m.role != mirror.role }
    end

    new_mirrors.each do |mirror|
      repo = db.get_repo?(mirror.repo_ref)

      if repo
        db.connection.exec <<-SQL, repo.id, mirror.role, shard_id
          UPDATE
            repos
          SET
            role = $2,
            shard_id = $3
          WHERE
            id = $1
          SQL

        db.log_activity "import_catalog:mirror:switched", repo_id: repo.id, shard_id: shard_id, metadata: {
          "role"         => mirror.role,
          "old_shard_id" => repo.shard_id,
          "old_role"     => repo.role,
        }
      else
        repo_id = db.connection.query_one(<<-SQL, mirror.repo_ref.resolver, mirror.repo_ref.url, mirror.role, shard_id, as: Int64)
          INSERT INTO repos
            (resolver, url, role, shard_id)
          VALUES
            ($1, $2, $3, $4)
          RETURNING id
          SQL

        db.log_activity "import_catalog:mirror:created", repo_id: repo_id, shard_id: shard_id, metadata: {
          "role" => mirror.role,
        }
      end
    end

    removed_mirrors.each do |mirror|
      repo = db.get_repo(mirror.repo_ref)
      db.connection.exec <<-SQL, repo.id
        UPDATE
          repos
        SET
          role = 'obsolete',
          shard_id = NULL
        WHERE
          id = $1
        SQL

      db.log_activity "import_catalog:mirror:obsoleted", repo_id: repo.id, shard_id: shard_id, metadata: {
        "old_role" => repo.role,
      }
    end

    updated_mirrors.each do |mirror|
      repo = db.get_repo(mirror.repo_ref)
      db.connection.exec <<-SQL, repo.id, mirror.role
        UPDATE
          repos
        SET
          role = $2
        WHERE
          id = $1
        SQL
      db.log_activity "import_catalog:mirror:role_changed", repo_id: repo.id, shard_id: shard_id, metadata: {
        "role"     => mirror.role,
        "old_role" => repo.role,
      }
    end
  end

  def archive_unreferenced_shards(db)
    unreferenced_shards = db.connection.query_all <<-SQL, as: Int64
      SELECT
        id
      FROM
        shards
      WHERE NOT EXISTS (
        SELECT 1
        FROM
          repos
        WHERE shard_id = shards.id
        )
      SQL

    unreferenced_shards.each do |shard_id|
      db.log_activity("import_catalog:shard:archived", nil, shard_id)
      db.connection.exec <<-SQL, shard_id
        UPDATE
          shards
        SET
          archived_at = NOW(),
          categories = '{}'
        WHERE
          id = $1
        SQL
    end
  end

  private def create_shard(db, entry, repo_id)
    Service::ImportShard.new(entry.repo_ref).import_shard(db, repo_id, entry)
  end

  private def update_shard(db, entry, shard_id)
    Service::UpdateShard.new(shard_id, entry).perform(db)
  end

  private def obsolete_removed_repos(db, valid_refs)
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

    dangling_repos = db.connection.query_all <<-SQL, resolvers, urls, as: {Int64, Int64?}
      WITH valid_refs AS (
        SELECT *
        FROM
          unnest($1::repo_resolver[], $2::citext[]) AS valid_refs (resolver, url)
      )
      SELECT
        repos.id, repos.shard_id
      FROM
        repos
      LEFT JOIN
        valid_refs v ON v.resolver = repos.resolver AND v.url = repos.url
      JOIN
        shards ON repos.shard_id = shards.id
      WHERE
        repos.role = 'canonical' AND
        v.resolver IS NULL AND
        array_length(shards.categories, 1) > 0
      SQL

    dangling_repos.each do |repo_id, shard_id|
      db.log_activity "import_catalog:repo:obsoleted", repo_id, shard_id
      db.connection.exec <<-SQL, repo_id
        UPDATE
          repos
        SET
          role = 'obsolete',
          shard_id = NULL
        WHERE
          id = $1
        SQL
    end
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
        return Path[checkout_path, "catalog"].to_s
      else
        abort "Can't checkout catalog from #{uri}: checkout path #{checkout_path.inspect} exists, but is not a git repository"
      end
    end

    Process.run("git", ["clone", uri.to_s, checkout_path.to_s], output: :inherit, error: :inherit)

    Path[checkout_path, "catalog"].to_s
  end
end
