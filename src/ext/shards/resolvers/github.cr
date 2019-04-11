require "json"
require "http/client"
require "../../../repo"

class Shards::GithubResolver
  @@graphql_client : HTTP::Client?

  def self.graphql_client
    @@graphql_client ||= HTTP::Client.new("api.github.com", 443, true)
  end

  def self.api_token
    @@api_token ||= ENV["GITHUB_TOKEN"]
  end

  def fetch_metadata : Repo::Metadata
    self.class.fetch_metadata(dependency["github"])
  end

  private def self.graphql_query : String
    {{ read_file("#{__DIR__}/github-repo-metadata.graphql") }}
  end

  def self.fetch_metadata(path)
    owner, name = path.split("/")
    body = {query: graphql_query, variables: {owner: owner, name: name}}
    response = graphql_client.post "/graphql", body: body.to_json, headers: HTTP::Headers{"Authorization" => "bearer #{api_token}"}

    raise Shards::Error.new("Repository unavailable") unless response.status_code == 200

    metadata = Repo::Metadata.from_github_graphql(response.body)

    raise Shards::Error.new("Invalid response") unless metadata

    metadata
  end
end

struct Repo::Metadata
  def self.from_github_graphql(string)
    pull = JSON::PullParser.new(string)
    metadata = nil
    pull.read_object do |key|
      case key
      when "data"
        pull.read_object do |key|
          if key == "repository"
            pull.read_null_or do
              metadata = new(github_pull: pull)
            end
          else
            pull.skip
          end
        end
      when "errors"
        errors = [] of String
        pull.read_array do
          pull.on_key!("message") do
            errors << pull.read_string
          end
        end
        raise Shards::Error.new("Repository error: #{errors.join(", ")}")
      else
        pull.skip
      end
    end

    metadata
  end

  def initialize(github_pull pull : JSON::PullParser)
    pull.read_object do |key|
      case key
      when "forks"
        pull.on_key!("totalCount") do
          @forks_count = pull.read?(Int32)
        end
      when "stargazers"
        pull.on_key!("totalCount") do
          @stargazers_count = pull.read?(Int32)
        end
      when "watchers"
        pull.on_key!("totalCount") do
          @watchers_count = pull.read?(Int32)
        end
      when "createdAt"
        @created_at = Time.new(pull)
      when "description"
        @description = pull.read_string_or_null
      when "hasIssuesEnabled"
        @issues_enabled = pull.read_bool
      when "hasWikiEnabled"
        @wiki_enabled = pull.read_bool
      when "homepageUrl"
        @homepage_url = pull.read_string_or_null
      when "isArchived"
        @archived = pull.read_bool
      when "isFork"
        @fork = pull.read_bool
      when "isMirror"
        @mirror = pull.read_bool
      when "licenseInfo"
        pull.read_null_or do
          pull.on_key!("key") do
            @license = pull.read_string
          end
        end
      when "primaryLanguage"
        pull.read_null_or do
          pull.on_key!("name") do
            @primary_language = pull.read_string
          end
        end
      when "pushedAt"
        pull.read_null_or do
          @pushed_at = Time.new(pull)
        end
      when "closedIssues"
        pull.on_key!("totalCount") do
          @closed_issues_count = pull.read?(Int32)
        end
      when "openIssues"
        pull.on_key!("totalCount") do
          @open_issues_count = pull.read?(Int32)
        end
      when "closedPullRequests"
        pull.on_key!("totalCount") do
          @closed_pull_requests_count = pull.read?(Int32)
        end
      when "openPullRequests"
        pull.on_key!("totalCount") do
          @open_pull_requests_count = pull.read?(Int32)
        end
      when "mergedPullRequests"
        pull.on_key!("totalCount") do
          @merged_pull_requests_count = pull.read?(Int32)
        end
      when "repositoryTopics"
        topics = [] of String
        @topics = topics
        pull.on_key!("nodes") do
          pull.read_array do
            pull.on_key!("topic") do
              pull.on_key!("name") do
                topics << pull.read_string
              end
            end
          end
        end
      else
        pull.skip
      end
    end
  end

  #   # Unfortunate hack for a limitation in github's graphql API.
  #   # See https://github.com/rubytoolbox/rubytoolbox/pull/94#issuecomment-372489342
  #   # and https://platform.github.community/t/repository-redirects-in-api-v4-graphql/4417
  #   def resolve_repo(path)
  #     response = @client.head "https://github.com/#{path}"
  #     case response.status
  #     when 200
  #       return path
  #     # Instead of following 301s, the broken github path
  #     # (either coming from the catalog for github-only projects,
  #     # or from a rubygems urls) should somehow be flagged and
  #     # remapped locally, but this needs some more consideration
  #     # regarding the various possible cases
  #     when 301, 302
  #       location = Github.detect_repo_name response.headers["Location"]
  #       return location if location
  #     end

  #     raise UnknownRepoError, "Cannot find repo #{path} on github :("
  #   end
  # end
end
