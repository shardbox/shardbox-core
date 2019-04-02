class Category
  getter slug : String
  getter name : String
  getter description : String?
  getter entries_count : Int32
  getter! id : Int64

  def initialize(
      @slug : String,
      @name : String,
      @description : String? = nil,
      @entries_count : Int32 = 0,
      @id : Int64? = nil
    )
  end
end