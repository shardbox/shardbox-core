require "../repo/owner"
require "../fetchers/github_api"
require "./update_owner_metrics"

struct Service::CreateOwner
  property github_api : Shardbox::GitHubAPI { Shardbox::GitHubAPI.new }

  def initialize(@db : ShardsDB, @repo_ref : Repo::Ref)
  end

  def perform
    owner = Repo::Owner.from_repo_ref(@repo_ref)

    return unless owner

    db_owner = @db.get_owner?(owner.resolver, owner.slug)

    if db_owner
      # owner already exists in the database
      owner = db_owner
    else
      # owner does not yet exist, need to insert a new entry
      fetch_owner_info(owner)
      owner.id = @db.create_owner(owner)
      UpdateOwnerMetrics.new(@db).update_owner_metrics(owner.id)
    end

    assign_owner(owner)

    owner
  end

  private def assign_owner(owner)
    @db.set_owner(@repo_ref, owner.id)
    @db.update_owner_shards_count(owner.id)
  end

  def fetch_owner_info(owner)
    case owner.resolver
    when "github"
      CreateOwner.fetch_owner_info_github(owner, github_api)
    else
      # skip
    end
  end

  def self.fetch_owner_info_github(owner, github_api)
    data = github_api.fetch_owner_info(owner.slug)
    unless data
      # Skip if data could not be determined (for example GitHub API returns null when the owner was renamed)

      Raven.send_event Raven::Event.new(
        level: :info,
        message: "GitHub API returned null for owner",
        tags: {
          owner: owner.slug,
        }
      )

      return
    end

    data.each do |key, value|
      case key
      when "bio", "description"
        owner.description = value.as_s?
      when "name"
        owner.name = value.as_s?
      else
        owner.extra[key.underscore] = value
      end
    end
  end
end
