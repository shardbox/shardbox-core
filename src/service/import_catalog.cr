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
    repo_refs.each do |repo_ref|
      unless db.repo_exists?(repo_ref)
        Service::ImportShard.new(repo_ref).perform_later
      end
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
