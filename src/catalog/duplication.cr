class Catalog::DuplicateRepoError < Catalog::Error
  def self.new(repo : Repo::Ref, category : String, existing_entry : Catalog::Entry, existing_category : String, *, mirror = false)
    message = String.build do |io|
      io << "duplicate "
      io << (mirror ? "mirror " : "repo ")
      io << repo
      io << " also "
      if existing_entry.repo_ref != repo
        io << "on " << existing_entry.repo_ref << " "
      end
      io << "in " << existing_category
    end

    new(message, repo, category, existing_entry, existing_category)
  end

  def initialize(message : String, @repo : Repo::Ref, @category : String, @existing_entry : Catalog::Entry, @existing_category : String)
    super(message)
  end

  def message
    super.not_nil!
  end

  def to_s(io : IO)
    io << @category << ": "
    io << message
  end
end

class Catalog::Duplication
  def initialize
    @all_repos = {} of Repo::Ref => {String, Entry}
  end

  def register(category : String, entry : Entry)
    if error = check_duplicate_repo(category, entry)
      return error
    end

    @all_repos[entry.repo_ref] = {category, entry}
    entry.mirrors.each do |mirror|
      @all_repos[mirror.repo_ref] = {category, entry}
    end

    nil
  end

  private def check_duplicate_repo(category, entry)
    if existing = @all_repos[entry.repo_ref]?
      existing_entry = existing[1]
      if existing_entry.repo_ref == entry.repo_ref
        # existing is canonical
        if existing_entry.description && entry.description
          return DuplicateRepoError.new(entry.repo_ref, category, existing_entry, existing[0])
        elsif entry.description
          @all_repos[entry.repo_ref] = {category, entry}
        end
      else
        # existing is mirror
        return DuplicateRepoError.new(entry.repo_ref, category, existing_entry, existing[0])
      end
    end

    entry.mirrors.each do |mirror|
      if mirror.repo_ref == entry.repo_ref
        return DuplicateRepoError.new(mirror.repo_ref, category, entry, category, mirror: true)
      end
      if existing = @all_repos[mirror.repo_ref]?
        return DuplicateRepoError.new(mirror.repo_ref, category, existing[1], existing[0], mirror: true)
      end
    end
  end

  def foo
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
      if other_entry
        p! other_entry.description, shard.description
        return shard.repo_ref
      end
    end

    nil
  end
end
