require "json"
require "http/client"
require "../fetchers/github_api"

struct Service::FetchMetadata
  class FetchError < Exception
  end

  property github_api : Shardbox::GitHubAPI { Shardbox::GitHubAPI.new }

  def initialize(@repo_ref : Repo::Ref)
  end

  def fetch_repo_metadata
    case @repo_ref.resolver
    when "github"
      fetch_repo_metadata_github(@repo_ref)
    else
      nil
    end
  end

  def fetch_repo_metadata_github(repo_ref : Repo::Ref)
    owner = repo_ref.owner
    if owner.nil?
      raise FetchError.new("Invalid repo_ref #{repo_ref}")
    end
    github_api.fetch_repo_metadata(owner, repo_ref.name)
  end
end
