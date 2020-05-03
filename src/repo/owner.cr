class Repo::Owner
  property resolver : String
  property slug : String
  property name : String?
  property shards_count : Int32?
  property description : String?
  property email : String?
  property website_url : String?
  property extra : Hash(String, JSON::Any)
  property! id : Int64

  def initialize(@resolver : String, @slug : String,
      @name : String? = nil, @shards_count : Int32? = nil,
      @description : String? = nil, @email : String? = nil,
      @website_url : String? = nil, @extra : Hash(String, JSON::Any) = Hash(String, JSON::Any).new,
      *, @id : Int64? = nil)
  end

  def self.from_repo_ref(repo_ref : Ref) : Owner?
    if owner = repo_ref.owner
      new(repo_ref.resolver, owner)
    end
  end

  def_equals_and_hash @resolver, @slug, @name, @shards_count
end
