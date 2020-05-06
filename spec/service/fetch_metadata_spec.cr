require "spec"
require "../../src/service/fetch_metadata"

struct Shardbox::GitHubAPI
  property mock_repo_metadata : Repo::Metadata?

  def fetch_repo_metadata(owner : String, name : String)
    if mock = mock_repo_metadata
      return mock
    else
      previous_def
    end
  end
end

describe Service::FetchMetadata do
  describe "#fetch_repo_metadata" do
    it "returns nil for git" do
      service = Service::FetchMetadata.new(Repo::Ref.new("git", "foo"))
      service.fetch_repo_metadata.should be_nil
    end

    it "queries github graphql" do
      metadata = Repo::Metadata.new(created_at: Time.utc)
      service = Service::FetchMetadata.new(Repo::Ref.new("github", "foo/bar"))
      api = Shardbox::GitHubAPI.new("")
      api.mock_repo_metadata = metadata
      service.github_api = api
      service.fetch_repo_metadata.should eq metadata
    end
  end
end
