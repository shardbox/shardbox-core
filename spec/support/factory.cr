module Factory
  def self.create_repo(db, shard_id, ref : Repo::Ref, role = "canonical")
    db.create_repo Repo.new(shard_id, ref, role)
  end

  def self.create_shard(db, name = "shard", qualifier = "", description = nil)
    db.create_shard Shard.new(name, qualifier, description)
  end

  def self.create_release(db, shard_id = nil, version = "0.1.0", released_at = Time.utc_now,
                          spec = JSON.parse("{}"), revision_info = JSON.parse("{}"),
                          position = nil, latest = nil, yanked_at = nil)
    shard_id ||= create_shard(db)
    position_sql = position ? position.to_s : "(SELECT MAX(position) FROM releases WHERE shard_id = $1)"
    db.connection.query_one <<-SQL,
        INSERT INTO releases
          (shard_id, version, released_at, spec, revision_info, latest, yanked_at, position)
        VALUES
          ($1, $2, $3, $4, $5, $6, $7, #{position_sql})
        RETURNING id
        SQL
      shard_id, version, released_at.at_beginning_of_second, spec, revision_info, latest, yanked_at.try(&.at_beginning_of_second), as: {Int64}
  end

  def self.create_dependency(db, release_id : Int64, name : String, spec : JSON::Any, shard_id : Int64? = nil, scope = Dependency::Scope::RUNTIME, resolvable = true)
    db.connection.exec <<-SQL, release_id, name, spec.to_json, shard_id, scope, resolvable
        INSERT INTO dependencies
          (release_id, name, spec, shard_id, scope, resolvable)
        VALUES
          ($1, $2, $3::jsonb, $4, $5, $6)
        SQL
  end

  def self.build_tag(name, message = "tag #{name}", tagger = "mock tagger")
    tagger = Release::Signature.new(tagger, "", Time.utc_now.at_beginning_of_second) unless tagger.is_a?(Release::Signature)
    Release::Tag.new(name, message, tagger)
  end

  def self.build_commit(sha, time = Time.utc_now, author = "mock author", committer = "mock comitter", message = "commit #{sha}")
    author = Release::Signature.new(author, "", Time.utc_now.at_beginning_of_second) unless author.is_a?(Release::Signature)
    committer = Release::Signature.new(committer, "", Time.utc_now.at_beginning_of_second) unless committer.is_a?(Release::Signature)
    Release::Commit.new(sha, time.at_beginning_of_second, author, committer, message)
  end

  def self.build_revision_info(tag = "v0.0.0", hash = "12345678")
    Release::RevisionInfo.new Factory.build_tag(tag), Factory.build_commit(hash)
  end
end
