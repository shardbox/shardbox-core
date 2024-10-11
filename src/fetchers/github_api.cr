require "json"
require "http/client"
require "../repo"
require "./error"

struct Shardbox::GitHubAPI
  getter graphql_client : HTTP::Client { HTTP::Client.new("api.github.com", 443, true) }

  private getter query_repo_metadata : String = begin
    {{ read_file("#{__DIR__}/github_api-repo_metadata.graphql") }}
  end

  private getter query_owner_info : String = begin
    {{ read_file("#{__DIR__}/github_api-owner_info.graphql") }}
  end

  def initialize(@api_token = ENV["GITHUB_TOKEN"])
  end

  def query(query, variables)
    body = {query: query, variables: variables}
    response = graphql_client.post "/graphql", body: body.to_json, headers: HTTP::Headers{"Authorization" => "bearer #{@api_token}"}

    raise FetchError.new("Repository unavailable") unless response.status_code == 200

    response.body
  end

  def fetch_repo_metadata(owner : String, name : String) : Repo::Metadata?
    response = query(query_repo_metadata, {owner: owner, name: name})

    metadata = parse_github_graphql(response, "repository") do |pull|
      Repo::Metadata.new(pull)
    end

    metadata
  end

  def fetch_owner_info(login : String) : Hash(String, JSON::Any)?
    response = query(query_owner_info, {login: login})

    data = parse_github_graphql(response, "repositoryOwner") do |pull|
      Hash(String, JSON::Any).new(pull)
    end

    data
  end

  def parse_github_graphql(content, expected_key, &)
    pull = JSON::PullParser.new(content)

    pull.read_object do |key|
      case key
      when "data"
        pull.read_object do |key|
          if key == expected_key
            if pull.kind.null?
              return nil
            else
              return yield pull
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
        raise Shardbox::FetchError.new("Repository error: #{errors.join(", ")}")
      else
        pull.skip
      end
    end

    raise FetchError.new("Invalid response")
  rescue exc : JSON::ParseException
    raise FetchError.new("Invalid response", cause: exc)
  end
end

class Repo
  struct Metadata
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
  end
end
