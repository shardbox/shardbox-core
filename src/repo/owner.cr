class Repo::Owner
  property resolver : String
  property slug : String
  property name : String?
  property shards_count : Int32?
  property! id : Int64

  def initialize(@resolver : String, @slug : String, @name : String? = nil, @shards_count : Int32? = nil, *, @id : Int64? = nil)
  end

  def self.from_repo_ref(repo_ref : Ref) : Owner?
    if owner = repo_ref.owner
      new(repo_ref.resolver, owner)
    end
  end

  def_equals_and_hash @resolver, @slug, @name, @shards_count
end
