require "yaml"
require "json"
require "./repo"
require "./category"
require "uri"

class Catalog
  class Error < Exception
  end

  getter location : URI
  getter categories = Hash(String, ::Category).new
  @entries = {} of Repo::Ref => Entry

  def initialize(@location : URI)
  end

  def self.empty
    new URI.new
  end

  def self.new(location)
    new(URI.parse(location))
  end

  def self.read(location) : self
    catalog = new(location)
    catalog.read
    catalog
  end

  def read
    duplication = Duplication.new

    each_category do |yaml_category|
      category = ::Category.new(yaml_category.slug, yaml_category.name, yaml_category.description)
      categories[category.slug] = category
      yaml_category.shards.each do |shard|
        if error = duplication.register(yaml_category.slug, shard)
          raise error
        end

        if stored_entry = @entries[shard.repo_ref]?
          stored_entry.mirrors.concat(shard.mirrors)
          stored_entry.categories << yaml_category.slug
        else
          shard.categories << yaml_category.slug
          @entries[shard.repo_ref] = shard
        end
      end
    end
  end

  def self.duplicate_repo?(shard, mirrors, all_entries)
    # (1) The entry's repo is already specified as a mirror of another entry
    return shard.repo_ref if mirrors.includes?(shard.repo_ref)

    # (2) The
    if shard.mirrors.any? { |mirror| mirror.repo_ref == shard.repo_ref }
      return shard.repo_ref
    end

    shard.mirrors.each do |mirror|
      if all_entries[mirror.repo_ref]? || !mirrors.add?(mirror.repo_ref)
        return mirror.repo_ref
      end
    end

    if other_entry = all_entries[shard.repo_ref]?
      if other_entry.description && shard.description
        p! other_entry.description, shard.description
        return shard.repo_ref
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

  def find_canonical_entry(ref : Repo::Ref)
    entry?(ref) || begin
      @entries.find do |_, entry|
        entry.mirrors.find { |mirror| mirror.repo_ref == ref }
      end
    end
  end

  def each_category(&)
    local_path = check_out

    each_category(local_path) do |category|
      yield category
    end
  end

  def each_category(path : Path, &)
    unless File.directory?(path)
      raise Error.new "Can't read catalog at #{path}, directory does not exist."
    end
    found_a_file = false

    filenames = Dir.glob(path.join("*.yml").to_s).sort
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
      raise "Catalog at #{path} is empty."
    end
  end

  def check_out(checkout_path = "./catalog")
    if location.scheme == "file" || location.scheme.nil?
      return Path.new(location.path)
    end

    local_path = Path[checkout_path, "catalog"]
    if File.directory?(checkout_path)
      if Process.run("git", ["-C", checkout_path.to_s, "pull", location.to_s], output: :inherit, error: :inherit).success?
        return local_path
      else
        abort "Can't checkout catalog from #{location}: checkout path #{checkout_path.inspect} exists, but is not a git repository"
      end
    end

    Process.run("git", ["clone", location.to_s, checkout_path.to_s], output: :inherit, error: :inherit)

    local_path
  end
end

require "./catalog/*"
