require "github-cr"

class Shards::GithubResolver
  @client : GithubCr::Client
  def client
    @client ||= GithubCr::Client.new(ENV["GITHUB_USER"], ENV["GITHUB_KEY"])
  end

  def fetch_metadata : Hash(String, JSON::Any)
    client.repo(dependency["github"]).raw_json
  end
end
