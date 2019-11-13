require "yaml"
require "json"
require "./repo"
require "./category"

class Catalog
  class Error < Exception
  end

  getter categories = Hash(String, ::Category).new
  @entries = {} of Repo::Ref => Entry

  def initialize(catalog_location)
    @catalog_location = Path.new(catalog_location)
  end

  def self.read(catalog_location) : self
    catalog = new(catalog_location)
    mirrors = Set(Repo::Ref).new

    catalog.each_category do |yaml_category|
      category = ::Category.new(yaml_category.slug, yaml_category.name, yaml_category.description)
      catalog.categories[category.slug] = category
      yaml_category.shards.each do |shard|
        if stored_entry = catalog.@entries[shard.repo_ref]?
          stored_entry.mirrors.concat(shard.mirrors)
          stored_entry.categories << yaml_category.slug
        else
          shard.categories << yaml_category.slug
          catalog.@entries[shard.repo_ref] = shard
        end

        if duplicate_repo = duplicate_mirror?(shard, mirrors, catalog)
          raise Error.new("duplicate mirror #{duplicate_repo} in #{yaml_category.slug}")
        end
      end
    end

    catalog
  end

  def self.duplicate_mirror?(shard, mirrors, catalog)
    return shard.repo_ref if mirrors.includes?(shard.repo_ref)

    shard.mirrors.each do |mirror|
      if catalog.entry?(mirror.repo_ref) || !mirrors.add?(mirror.repo_ref)
        return mirror.repo_ref
      end
    end

    nil
  end

  def entries
    @entries.values
  end

  def entry?(repo_ref : Repo::Ref)
    @entries[repo_ref]?
  end

  def each_category
    unless File.directory?(@catalog_location)
      raise Error.new "Can't read catalog at #{@catalog_location}, directory does not exist."
    end
    found_a_file = false

    filenames = Dir.glob(@catalog_location.join("*.yml").to_s).sort
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
      raise "Catalog at #{@catalog_location} is empty."
    end
  end
end

require "./catalog/*"
