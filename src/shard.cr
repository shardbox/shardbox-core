class Shard
  getter name : String
  getter qualifier : String
  getter description : String?
  getter! id : Int64
  getter archived_at : Time?

  def initialize(@name : String, @qualifier : String = "", @description : String? = nil, @archived_at : Time? = nil, @id : Int64? = nil)
  end

  def_equals_and_hash name, qualifier, description, archived_at

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

  def archived?
    !archived_at.nil?
  end

  def to_s(io : IO)
    io << "#<Shard @name="
    @name.dump(io)
    io << ", @qualifier="
    @qualifier.dump(io)
    io << ", @description="
    @description.try &.dump(io)
    io << ", @archived_at="
    @archived_at.to_s(io)
    io << ">"
  end
end
