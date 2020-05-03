require "../repo/owner"

struct Service::CreateOwner
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
      owner.id = @db.create_owner(owner)
    end

    assign_owner(owner)

    owner
  end

  private def assign_owner(owner)
    @db.set_owner(@repo_ref, owner.id)
    @db.update_owner_shards_count(owner.id)
  end
end
