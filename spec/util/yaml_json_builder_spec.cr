require "spec"
require "../../src/util/yaml_json_builder"

describe YAML::JSONBuilder do
  it do
    yaml = YAML.parse(<<-YAML)
      foo: bar
      int: 123456
      int_s: "123456"
      float: 1.23
      arr: ["foo", 1, true]
      baz:
        qux: bam
        qax: [1, 2, 3]
        bool: true
      YAML

    String.build do |io|
      YAML::JSONBuilder.build(io) do |builder|
        yaml.to_yaml(builder)
      end
    end.should eq <<-JSON
      {"foo":"bar","int":123456,"int_s":"123456","float":1.23,"arr":["foo",1,true],"baz":{"qux":"bam","qax":[1,2,3],"bool":true}}
      JSON
  end
end
