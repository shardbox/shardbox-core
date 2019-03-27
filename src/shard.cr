class Shard
  getter name : String
  getter qualifier : String
  getter description : String?
  getter! id : Int64

  def initialize(@name : String, @qualifier : String = "", @description : String? = nil, @id : Int64? = nil)
  end

  def_equals_and_hash name, qualifier, description

  def display_name
    if qualifier.empty?
      name
    else
      "#{name}~#{qualifier}"
    end
  end

  def slug
    display_name.downcase
  end

  def to_s(io : IO)
    io << "#<Shard @name="
    @name.dump(io)
    io << ", "
    io << "@qualifier="
    @qualifier.dump(io)
    io << ", "
    io << "@description="
    @description.try &.dump(io)
    io << ">"
  end
end
