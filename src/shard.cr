class Shard
  getter name : String
  getter qualifier : String
  getter description : String?

  # getter repos : Array(Repo::Ref)
  # getter canonical_repo : Repo::Ref?

  def initialize(@name : String, @qualifier : String = "", @description : String? = nil)
  end

  # @canonical_repo : Repo::Ref? = nil, @repos : Array(Repo::Ref) = [] of Repo::Ref,

  # def self.new(name : String, repo : Repo::Ref, description : String? = nil, qualifier : String = "")
  #   new(name, repo, [repo], description, qualifier)
  # end

  def_equals_and_hash name, qualifier, description # , repos

  def to_s(io : IO)
    io << "#<Shard @name="
    @name.dump(io)
    io << ", "
    io << "@qualifier="
    @qualifier.dump(io)
    io << ", "
    io << "@description="
    @description.try &.dump(io)
    io << ", "
    # io << "@repos="
    # @repos.to_s(io)
    # io << ">"
  end
end
