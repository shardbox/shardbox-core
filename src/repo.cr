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

  getter metadata : Metadata

  def_equals_and_hash ref, role

  getter synced_at : Time?

  getter sync_failed_at : Time?

  getter! id : Int64?

  def initialize(
    @ref : Ref, @shard_id : Int64?,
    @role : Role = :canonical, @metadata = Metadata.new,
    @synced_at : Time? = nil, @sync_failed_at : Time? = nil,
    @id : Int64? = nil
  )
  end

  def self.new(
    resolver : String, url : String, shard_id : Int64?,
    role : String = "canonical", metadata = Metadata.new,
    synced_at : Time? = nil, sync_failed_at : Time? = nil,
    id : Int64? = nil
  )
    new(Ref.new(resolver, url), shard_id, Role.parse(role), metadata, synced_at, sync_failed_at, id)
  end

  record Metadata,
    forks_count : Int32? = nil,
    stargazers_count : Int32? = nil,
    watchers_count : Int32? = nil,
    created_at : Time? = nil,
    description : String? = nil,
    issues_enabled : Bool? = nil,
    wiki_enabled : Bool? = nil,
    homepage_url : String? = nil,
    archived : Bool? = nil,
    fork : Bool? = nil,
    mirror : Bool? = nil,
    license : String? = nil,
    primary_language : String? = nil,
    pushed_at : Time? = nil,
    closed_issues_count : Int32? = nil,
    open_issues_count : Int32? = nil,
    closed_pull_requests_count : Int32? = nil,
    open_pull_requests_count : Int32? = nil,
    merged_pull_requests_count : Int32? = nil,
    topics : Array(String)? = nil do
    include JSON::Serializable
  end
end

require "./repo/ref"
