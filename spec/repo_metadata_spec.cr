require "spec"
require "../src/repo"

describe Repo::Metadata do
  describe "for Github graphql" do
    it ".from_github_graphql" do
      File.open("#{__DIR__}/data/repo_metadata-github-graphql-response.json", "r") do |file|
        metadata = Repo::Metadata.from_github_graphql(file)
        metadata.should eq Repo::Metadata.new(
          forks_count: 964,
          stargazers_count: 13060,
          watchers_count: 479,
          created_at: Time.utc(2012, 11, 27, 17, 32, 32),
          description: "The Crystal Programming Language",
          issues_enabled: true,
          wiki_enabled: true,
          homepage_url: "https://crystal-lang.org",
          archived: false,
          fork: false,
          mirror: false,
          license: "other",
          primary_language: "Crystal",
          pushed_at: Time.utc(2019, 4, 8, 23, 53, 17),
          closed_issues_count: 3587,
          open_issues_count: 717,
          closed_pull_requests_count: 673,
          open_pull_requests_count: 154,
          merged_pull_requests_count: 2408,
          topics: ["crystal", "language", "efficiency"]
        )
      end
    end
  end
end
