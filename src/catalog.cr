require "./category"

module Catalog
  def self.each_category(catalog_location)
    Dir.glob(File.join(catalog_location, "*.yml")).each do |filename|
      File.open(filename) do |file|
        begin
          category = Category.from_yaml(file)
        rescue exc
          raise Exception.new("Failure reading catalog #{filename}", cause: exc)
        end

        yield category
      end
    end
  end
end
