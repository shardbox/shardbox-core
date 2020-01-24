class Catalog::Category
  include YAML::Serializable
  include YAML::Serializable::Strict

  getter name : String

  getter description : String?

  getter shards : Array(Entry) = [] of Catalog::Entry

  @[YAML::Field(ignore: true)]
  property! slug : String?

  def initialize(@name : String, @description : String? = nil, @slug = nil)
    @slug ||= @name
  end
end
