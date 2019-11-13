require "yaml"
require "json"
require "./repo"
require "./category"
require "./catalog/*"

module Catalog
  class Error < Exception
  end

  def self.read(catalog_location)
    categories = Hash(String, ::Category).new
    entries = {} of Repo::Ref => Entry
    mirrors = Set(Repo::Ref).new

    each_category(catalog_location) do |yaml_category|
      category = ::Category.new(yaml_category.slug, yaml_category.name, yaml_category.description)
      categories[category.slug] = category
      yaml_category.shards.each do |shard|
        if stored_entry = entries[shard.repo_ref]?
          stored_entry.mirrors.concat(shard.mirrors)
          stored_entry.categories << yaml_category.slug
        else
          shard.categories << yaml_category.slug
          entries[shard.repo_ref] = shard
        end

        if duplicate_repo = duplicate_mirror?(shard, mirrors, entries)
          raise Error.new("duplicate mirror #{duplicate_repo} in #{yaml_category.slug}")
        end
      end
    end

    return categories, entries.values
  end

  def self.duplicate_mirror?(shard, mirrors, entries)
    return shard.repo_ref if mirrors.includes?(shard.repo_ref)

    shard.mirrors.each do |mirror|
      if entries.has_key?(mirror.repo_ref) || !mirrors.add?(mirror.repo_ref)
        return mirror.repo_ref
      end
    end

    nil
  end

  def self.each_category(catalog_location)
    unless File.directory?(catalog_location)
      raise Error.new "Can't read catalog at #{catalog_location}, directory does not exist."
    end
    found_a_file = false

    filenames = Dir.glob(File.join(catalog_location, "*.yml")).sort
    filenames.each do |filename|
      found_a_file = true
      File.open(filename) do |file|
        begin
          category = Category.from_yaml(file)
        rescue exc
          raise Error.new("Failure reading catalog #{filename}", cause: exc)
        end

        category.slug = File.basename(filename, ".yml")

        yield category
      end
    end
    unless found_a_file
      raise "Catalog at #{catalog_location} is empty."
    end
  end
end
