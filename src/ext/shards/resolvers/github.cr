require "http/client"

class Shards::GithubResolver
  @client : HTTP::Client?
  def client
    @client ||= begin
      client = HTTP::Client.new("api.github.com", 443, true)
      client.basic_auth ENV["GITHUB_USER"], ENV["GITHUB_KEY"]
      client
    end
  end

  def fetch_metadata : Hash(String, JSON::Any)
    url = "/repos/#{dependency["github"]}"
    p! client
    p! url
    response = client.get(url)
    json = JSON.parse(response.body)
    json.as_h
  end
end
