class Repo
  class Owner
    property resolver : String
    property slug : String
    property name : String?
    property description : String?
    property extra : Hash(String, JSON::Any)
    property shards_count : Int32?
    property! id : Int64

    def initialize(@resolver : String, @slug : String,
                   @name : String? = nil, @description : String? = nil,
                   @extra : Hash(String, JSON::Any) = Hash(String, JSON::Any).new,
                   @shards_count : Int32? = nil,
                   *, @id : Int64? = nil)
    end

    def self.from_repo_ref(repo_ref : Ref) : Owner?
      if owner = repo_ref.owner
        new(repo_ref.resolver, owner)
      end
    end

    def_equals_and_hash @resolver, @slug, @name, @description, @extra, @shards_count

    def website_url : String?
      extra["website_url"]?.try(&.as_s?)
    end

    record Metrics,
      shards_count : Int32,
      dependents_count : Int32,
      transitive_dependents_count : Int32,
      dev_dependents_count : Int32,
      transitive_dependencies_count : Int32,
      dev_dependencies_count : Int32,
      dependencies_count : Int32,
      popularity : Float32,
      created_at : Time? = nil
  end
end
