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
  getter shard_id : Int64

  # Returns the identifier of this repo, consisting of resolver and url.
  getter ref : Ref

  # Returns the role of this repo for the shard (defaults to `canonical`).
  getter role : String

  getter metadata : Hash(String, JSON::Any)

  def_equals_and_hash ref, role

  getter synced_at : Time?

  def initialize(@shard_id : Int64, @ref : Ref, @role : String = "canonical", @metadata = {} of String => JSON::Any, @synced_at : Time? = nil)
  end

  def self.new(shard_id : Int64, resolver : String, url : String, role : String = "canonical", metadata = {} of String => JSON::Any, synced_at : Time? = nil)
    new(shard_id, Ref.new(resolver, url), role, metadata, synced_at)
  end
end

require "./repo/ref"
