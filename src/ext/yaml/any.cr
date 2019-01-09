struct YAML::Any
  def to_json(builder : JSON::Builder)
    if (raw = self.raw).is_a?(Slice)
      raise "Can't serialize #{raw.class} to JSON"
    else
      raw.to_json(builder)
    end
  end
end
