require "spec"
require "../src/shard"

describe Shard do
  it ".new" do
    shard = Shard.new("jerusalem")
    shard.name.should eq "jerusalem"
  end

  it "#display_name" do
    Shard.new("foo").display_name.should eq "foo"
    Shard.new("foo", "bar").display_name.should eq "foo~bar"
  end

  it "#archived?" do
    Shard.new("foo", archived_at: nil).archived?.should be_false
    Shard.new("foo", archived_at: Time.utc).archived?.should be_true
  end
end
