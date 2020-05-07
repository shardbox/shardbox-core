require "spec"
require "../../src/fetchers/github_api"
require "webmock"

describe Shardbox::GitHubAPI do
  describe "#fetch_repo_metadata" do
    it "queries github graphql" do
      WebMock.wrap do
        WebMock.stub(:post, "https://api.github.com/graphql").to_return do |request|
          body = request.body.not_nil!.gets_to_end
          body.should contain %("variables":{"owner":"foo","name":"bar"})

          HTTP::Client::Response.new(:ok, <<-JSON)
            {
              "data": {
                "repository": {
                  "description": "foo bar baz"
                }
              }
            }
            JSON
        end
        api = Shardbox::GitHubAPI.new("")
        repo_info = api.fetch_repo_metadata("foo", "bar")

        repo_info.should eq Repo::Metadata.new(description: "foo bar baz")
      end
    end

    it "raises when endpoint unavailable" do
      WebMock.wrap do
        WebMock.stub(:post, "https://api.github.com/graphql").to_return(status: 401)

        api = Shardbox::GitHubAPI.new("")

        expect_raises(Shardbox::FetchError, "Repository unavailable") do
          api.fetch_repo_metadata("foo", "bar")
        end
      end
    end

    it "raises when response is invalid" do
      WebMock.wrap do
        WebMock.stub(:post, "https://api.github.com/graphql").to_return(status: 200)

        api = Shardbox::GitHubAPI.new("")

        expect_raises(Shardbox::FetchError, "Invalid response") do
          api.fetch_repo_metadata("foo", "bar")
        end
      end
    end
  end

  describe "#fetch_repository_owner" do
    it "queries from GraphQL" do
      WebMock.wrap do
        WebMock.stub(:post, "https://api.github.com/graphql").to_return(<<-JSON, status: 200)
          {
            "data": {
              "repositoryOwner": {
                "description": "foo"
              }
            }
          }
          JSON

        api = Shardbox::GitHubAPI.new("")

        api.fetch_owner_info("foo").should eq({
          "description" => JSON::Any.new("foo"),
        })
      end
    end

    it "handles repositoryOwner: null" do
      WebMock.wrap do
        WebMock.stub(:post, "https://api.github.com/graphql").to_return(<<-JSON, status: 200)
          {
            "data": {
              "repositoryOwner": null
            }
          }
          JSON

        api = Shardbox::GitHubAPI.new("")

        api.fetch_owner_info("foo").should be_nil
      end
    end
  end
end
