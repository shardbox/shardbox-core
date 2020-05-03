require "spec"
require "../../src/service/fetch_metadata"
require "webmock"

describe Service::FetchMetadata do
  describe "#fetch_metadata" do
    it "returns nil for git" do
      service = Service::FetchMetadata.new(Repo::Ref.new("git", "foo"))
      service.fetch_metadata.should be_nil
    end

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
        service = Service::FetchMetadata.new(Repo::Ref.new("github", "foo/bar"))
        service.api_token = ""
        service.fetch_metadata.should eq Repo::Metadata.new(description: "foo bar baz")
      end
    end

    it "raises when endpoint unavailable" do
      WebMock.wrap do
        WebMock.stub(:post, "https://api.github.com/graphql").to_return(status: 401)

        service = Service::FetchMetadata.new(Repo::Ref.new("github", "foo/bar"))
        service.api_token = ""

        expect_raises(Service::FetchMetadata::Error, "Repository unavailable") do
          service.fetch_metadata
        end
      end
    end

    it "raises when response is invalid" do
      WebMock.wrap do
        WebMock.stub(:post, "https://api.github.com/graphql").to_return(status: 200)

        service = Service::FetchMetadata.new(Repo::Ref.new("github", "foo/bar"))
        service.api_token = ""

        expect_raises(Service::FetchMetadata::Error, "Invalid response") do
          service.fetch_metadata
        end
      end
    end
  end
end
