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

    def to_s(io : IO)
      io << to_s
    end

    def to_s
      super.downcase
    end
  end

  # Returns a reference to the shard hosted in this repo.
  getter shard_id : Int64?

  # Returns the identifier of this repo, consisting of resolver and url.
  getter ref : Ref

  # Returns the role of this repo for the shard (defaults to `canonical`).
  getter role : Role

  getter metadata : Hash(String, JSON::Any)

  def_equals_and_hash ref, role

  getter synced_at : Time?

  getter sync_failed_at : Time?

  getter! id : Int64?

  def initialize(
      @ref : Ref, @shard_id : Int64?,
      role : Role | String = :canonical, @metadata = {} of String => JSON::Any,
      @synced_at : Time? = nil, @sync_failed_at : Time? = nil,
      @id : Int64? = nil
    )
    role = Role.parse(role) if role.is_a?(String)
    @role = role
  end

  def self.new(
      resolver : String, url : String,shard_id : Int64?,
      role : Role | String = :canonical, metadata = {} of String => JSON::Any,
      synced_at : Time? = nil, sync_failed_at : Time? = nil,
      id : Int64? = nil
    )
    new(Ref.new(resolver, url), shard_id, role, metadata, synced_at, sync_failed_at, id)
  end
end

require "./repo/ref"
