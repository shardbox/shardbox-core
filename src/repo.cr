require "uri"
require "json"

class Repo
  RESOLVERS = {"git", "github", "gitlab", "bitbucket"}

  enum Role
    # Main repository of a shard.
    CANONICAL
    # A mirror of the main repository.
    MIRROR
    # A previously used repository, associated with the shard.
    LEGACY
  end

  # Returns a reference to the shard hosted in this repo.
  getter shard_id : Int32

  # Returns the identifier of this repo, consisting of resolver and url.
  getter ref : Ref

  # Returns the role of this repo for the shard (defaults to `canonical`).
  getter role : String

  def_equals_and_hash ref, role

  def initialize(@shard_id : Int32, @ref : Ref, @role : String = "canonical")
  end

  def self.new(shard_id : Int32, resolver : String, url : String, role : String = "canonical")
    new(shard_id, Ref.new(resolver, url), role)
  end
end

require "./repo/ref"
