require "spec"
require "../src/db"
require "./support/db"

describe ShardsDB do
  it ".connect" do
    connected = false
    ShardsDB.connect do |connection|
      connected = true
    end
    connected.should be_true
  end

  describe "#persist_shard" do
    it "persists and reloads" do
      shard = Shard.new("shard", Repo::Ref.new("github", "shard/shard"), "description")

      transaction do |db|
        db.persist_shard(shard)

        db.find_shard("shard").should eq shard
      end
    end

    it "presists with repostiory" do
      shard = Shard.new("shard", repos: [Repo::Ref.new("github", "crystal-lang/crystal")])

      transaction do |db|
        db.persist_shard(shard)

        db.find_shard("shard").should eq shard
      end
    end
  end

  describe "persisting release" do
    it "persists" do
      shard = Shard.new("shard", description: "description")

      transaction do |db|
        db.persist_shard(shard)

        release = Release.new("0.1.0", Release::RevisionInfo.from_json(%({"tag":{},"commit":{}})))

        db.persist_release(shard.name, release, 1)

        db.find_release(shard.name, "0.1.0").should eq release
      end
    end

    it "persists with dependencies" do
      shard = Shard.new("shard")
      dependency_shard = Shard.new("dependency")

      transaction do |db, transaction|
        db.persist_shard(shard)
        db.persist_shard(dependency_shard)

        release = Release.new("0.1.0", "0123456789abcdef", Time.utc_now.at_beginning_of_second)
        release.dependencies << Dependency.new(dependency_shard, "0.2.0")

        db.persist_release(shard.name, release, 1)

        db.find_release(shard.name, "0.1.0").should eq release
      end
    end

    it "persists with spec" do
      shard = Shard.new("shard")

      transaction do |db|
        db.persist_shard(shard)

        spec = {
          "crystal" => JSON::Any.new("1.0"),
          "custom"  => JSON::Any.new("value"),
        }
        release = Release.new("0.1.0", "012345678", Time.utc_now.at_beginning_of_second, spec)

        db.persist_release(shard.name, release, 1)

        found = db.find_release(shard.name, "0.1.0")
        found.should eq release
      end
    end
  end
end
