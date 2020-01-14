require "./dependency"
require "json"

class Release
  record RevisionInfo, tag : Tag?, commit : Commit do
    include JSON::Serializable
  end

  record Commit, sha : String, time : Time, author : Signature, committer : Signature, message : String do
    include JSON::Serializable
  end

  record Tag, name : String, message : String, tagger : Signature do
    include JSON::Serializable
  end

  record Signature, name : String, email : String, time : Time do
    include JSON::Serializable
  end

  property version : String
  property released_at : Time
  property! revision_info : RevisionInfo?
  property? yanked_at : Time?
  getter spec : Hash(String, JSON::Any)
  getter? latest : Bool
  property! id : Int64

  def self.new(
    version : String,
    revision_info : RevisionInfo,
    spec : Hash(String, JSON::Any) = {} of String => JSON::Any,
    yanked_at : Time? = nil,
    latest : Bool = false
  )
    new(
      version: version,
      released_at: revision_info.commit.time,
      revision_info: revision_info,
      spec: spec,
      yanked_at: yanked_at,
      latest: latest
    )
  end

  def initialize(
    @version : String,
    @released_at : Time,
    @revision_info : RevisionInfo? = nil,
    @spec : Hash(String, JSON::Any) = {} of String => JSON::Any,
    @yanked_at : Time? = nil,
    @latest : Bool = false,
    @id : Int64? = nil
  )
  end

  def revision_identifier
    if tag = revision_info.tag
      tag.name
    else
      revision_info.commit.sha
    end
  end

  def license : String?
    spec["license"]?.try &.as_s
  end

  def description : String?
    spec["description"]?.try &.as_s
  end

  def crystal : String?
    if crystal = spec["crystal"]?
      crystal.as_s? || crystal.as_f?.try &.to_s # A version might have been encoded as a number in YAML
    end
  end

  def yanked? : Bool
    !yanked_at?.nil?
  end

  def_equals_and_hash version, revision_info, released_at, spec
end
