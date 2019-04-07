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
    categories, repo_categorizations = read_catalog

    create_or_update_categories(db, categories)
    delete_obsolete_categories(db, categories)

    update_categorizations(db, repo_categorizations)
    delete_obsolete_categorizations(db, repo_categorizations)

    import_shards(db, repo_categorizations.keys)
  end

  def import_shards(db, repo_refs)
    new_repos = [] of {Repo::Ref, Int64}
    statement = db.connection.build(<<-SQL)
      INSERT INTO repos
        (resolver, url)
      VALUES
        ($1, $2)
      ON CONFLICT ON CONSTRAINT repos_url_uniq DO NOTHING
      RETURNING id
      SQL
    repo_refs.each do |repo_ref|
      result = statement.query(repo_ref.resolver, repo_ref.url)

      # If repo_id is NULL the repo already exists in the database. We only need
      # to run ImportShard if it is fresh.
      inserted = result.move_next
      if inserted
        new_repos << {repo_ref, result.read(Int64)}
      end
      result.close
    end

    if db.responds_to? :commit
      db.commit
    end

    new_repos.each do |repo_ref, repo_id|
      Service::ImportShard.new(repo_ref).import_shard(db,repo_id)
    end
  end

  def read_catalog
    categories = Array(Category).new
    # This hash maps shards to categories
    repo_categorizations = Hash(Repo::Ref, Array(String)).new { |hash, key| hash[key] = [] of String }

    Catalog.each_category(@catalog_location) do |yaml_category, slug|
      category = Category.new(slug, yaml_category.name, yaml_category.description)
      categories << category
      yaml_category.shards.each do |shard|
        repo_categorizations[shard.repo_ref] << slug
      end
    end

    return categories, repo_categorizations
  end

  def create_or_update_categories(db, categories)
    categories.each do |category|
      db.create_or_update_category(category)
    end
  end

  def delete_obsolete_categories(db, categories)
    db.remove_categories(categories.map(&.slug))
  end

  def update_categorizations(db, repo_categorizations)
    repo_categorizations.each do |repo_ref, categories|
      db.update_categorization(repo_ref, categories)
    end
  end

  def delete_obsolete_categorizations(db, repo_categorizations)
    db.delete_categorizations(repo_categorizations.keys)
  end
end
