require "spec"
require "../src/shard"

describe Shard do
  it ".new" do
    shard = Shard.new("jerusalem")
    shard.name.should eq "jerusalem"
  end

  it "#name" do
  end
end
