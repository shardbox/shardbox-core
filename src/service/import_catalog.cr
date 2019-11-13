require "../catalog"
require "./import_categories"
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
    catalog = Catalog.read(@catalog_location)

    category_stats = ImportCategories.new(db, catalog).perform

    import_repos(db, catalog.entries)

    category_stats
  end

  def import_repos(db, entries)
    entries.each do |entry|
      shard_id = import_repo(db, entry, entries)
      if shard_id
        update_mirrors(db, entry, shard_id)
      else
        # some failure with shard creation, skipping
      end
    end

    obsolete_removed_repos(db, entries.map &.repo_ref)
    archive_unreferenced_shards(db)
  end

  def import_repo(db, entry, entries) : Int64?
    repo = db.get_repo?(entry.repo_ref)

    unless repo
      # Repo does not exist, create it
      return create_repo(db, entry)
    end

    shard_id = repo.shard_id

    unless shard_id
      # Repo exists, but not associated with a shard (obsolete)
      if repo.role.obsolete?
        db.log_activity "import_catalog:repo:reactivated", repo_id: repo.id
      end
      repo.role = :canonical
      set_role(db, repo.ref, :canonical)

      return import_shard(db, entry, repo)
    end

    if repo.role.canonical?
      # Repo is already canonical, only need to update.
      update_shard(db, entry, shard_id)
      return shard_id
    end

    # Repo exists, but is currently a mirror. Try to find the canonical.

    canonical_ref = db.find_canonical_ref?(shard_id)
    unless canonical_ref
      # A canonical repo does not exist, taking over.
      set_role(db, repo.ref, :canonical)
      update_shard(db, entry, shard_id)
      return shard_id
    end

    if mirror = entry.mirror?(canonical_ref)
      # The current canonical becomes a mirror
      switch_canonical(db, entry, repo, canonical_ref, mirror.role)
    else
      # Check whether the current canonical is in the catalog,
      # either as canonical or mirror.
      canonical_entry = find_canonical_entry(entries, canonical_ref)
      if canonical_entry
        # The current canonical is referenced in an other entry,
        # so this one is to be considered a new shard.
        repo = Repo.new(repo.ref, shard_id: nil, role: :canonical, id: repo.id)
        set_role(db, repo.ref, :canonical, nil)
        shard_id = import_shard(db, entry, repo)
      else
        # The current canonical is not referenced in the catalog,
        # so it's going obsolete.
        # This is unusual. Old canonicals should be kept as
        # legacy mirrors.
        switch_canonical(db, entry, repo, canonical_ref, :obsolete)
      end
    end

    shard_id
  end

  private def switch_canonical(db, entry, repo, canonical_ref, role : Repo::Role)
    shard_id = repo.shard_id.not_nil!

    set_role(db, canonical_ref, role)
    set_role(db, repo.ref, :canonical)

    db.log_activity "import_catalog:shard:canonical_switched", repo_id: repo.id, shard_id: repo.shard_id, metadata: {"old_repo" => canonical_ref.to_s}

    update_shard(db, entry, shard_id)
  end

  private def create_repo(db, entry)
    repo = Repo.new(entry.repo_ref, nil, :canonical)
    repo.id = db.create_repo(repo)

    db.log_activity "import_catalog:repo:created", repo_id: repo.id

    import_shard(db, entry, repo)
  end

  private def import_shard(db, entry, repo)
    shard_id = create_shard(db, entry, repo)

    if shard_id && !entry.categories.empty?
      db.update_categorization(shard_id, entry.categories)
    end

    shard_id
  end

  private def create_shard(db, entry, repo)
    Service::ImportShard.new(repo.ref).import_shard(db, repo, entry)
  end

  private def update_shard(db, entry, shard_id : Int64)
    Service::UpdateShard.new(shard_id, entry).perform(db)
  end

  private def find_canonical_entry(entries, ref)
    entries.find do |entry|
      entry.repo_ref == ref || entry.mirrors.find { |mirror| mirror.repo_ref == ref }
    end
  end

  def set_role(db, repo_ref : Repo::Ref, role : Repo::Role)
    if role.obsolete?
      return set_role(db, repo_ref, role, nil)
    end

    db.connection.exec <<-SQL, repo_ref.resolver, repo_ref.url, role
      UPDATE repos
      SET
        role = $3
      WHERE
        resolver = $1 AND url = $2
      SQL
  end

  def set_role(db, repo_ref : Repo::Ref, role : Repo::Role, shard_id)
    db.connection.exec <<-SQL, repo_ref.resolver, repo_ref.url, role, shard_id
      UPDATE repos
      SET
        role = $3,
        shard_id = $4
      WHERE
        resolver = $1 AND url = $2
      SQL
  end

  def update_mirrors(db, entry, shard_id)
    repos = db.find_mirror_repos(shard_id)

    entry.mirrors.each do |mirror|
      next if repos.any? { |repo| repo.ref == mirror.repo_ref }

      repo = db.get_repo?(mirror.repo_ref)

      if repo
        set_role(db, repo.ref, mirror.role, shard_id)

        db.log_activity "import_catalog:mirror:switched", repo_id: repo.id, shard_id: shard_id, metadata: {
          "role"         => mirror.role,
          "old_shard_id" => repo.shard_id,
          "old_role"     => repo.role,
        }
      else
        repo = Repo.new(mirror.repo_ref, shard_id, mirror.role)
        repo.id = db.create_repo(repo)

        db.log_activity "import_catalog:mirror:created", repo_id: repo.id, shard_id: shard_id, metadata: {
          "role" => repo.role,
        }
      end
    end

    repos.each do |repo|
      if mirror = entry.mirrors.find { |m| m.repo_ref == repo.ref }
        if mirror.role != repo.role
          # update mirror
          set_role(db, repo.ref, mirror.role)

          db.log_activity "import_catalog:mirror:role_changed", repo_id: repo.id, shard_id: shard_id, metadata: {
            "role"     => mirror.role,
            "old_role" => repo.role,
          }
        end
      else
        # remove mirror
        obsolete_repo(db, repo)
      end
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

  private def obsolete_removed_repos(db, valid_refs)
    resolvers = Array(String).new(valid_refs.size)
    urls = Array(String).new(valid_refs.size)
    valid_refs.each do |repo_ref|
      resolvers << repo_ref.resolver
      urls << repo_ref.url
    end

    # The following query is a bit complex.
    # It selects obsolete repos that have been removed from the catalog.
    # If any of the following conditions is met, the repo is not obsolete:
    # 1) It's mentioned as canonical or mirror repo in the catalog (
    #    these are all collected in `valid_refs`)
    # 2) The referenced shard has no categories. Those repos have been discoverd
    #    as recursive dependencies. They need to be categorized, not obsoleted.
    # 3) It does not reference a shard. The repo entry has probably just been
    #    inserted from a dependency and waits for sync. After that it would meet
    #    condition 2).

    dangling_repos = db.connection.query_all <<-SQL, resolvers, urls, as: {Int64, Int64?, String, String}
      WITH valid_refs AS (
        SELECT *
        FROM
          unnest($1::repo_resolver[], $2::citext[]) AS valid_refs (resolver, url)
      )
      SELECT
        repos.id, repos.shard_id, repos.resolver::text, repos.url::text
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

    dangling_repos.each do |repo_id, shard_id, resolver, url|
      obsolete_repo(db, Repo.new(Repo::Ref.new(resolver, url), role: :canonical, id: repo_id, shard_id: shard_id))
    end
  end

  def obsolete_repo(db, repo)
    set_role(db, repo.ref, :obsolete)
    db.log_activity "import_catalog:repo:obsoleted", repo.id, repo.shard_id, metadata: {
      "old_role" => repo.role,
    }
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
