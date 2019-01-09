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
    all_refs = read_categories

    all_refs.each do |repo_ref|
      unless db.repo_exists?(repo_ref)
        Service::ImportShard.new(repo_ref).perform_later
      end
    end
  end

  def read_categories
    all_refs = Set(Repo::Ref).new
    Catalog.each_category(@catalog_location) do |category|
      category.shards.each do |entry|
        all_refs << entry.repo_ref
      end
    end

    all_refs
  end
end
