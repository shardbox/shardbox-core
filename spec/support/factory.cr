module Factory
  def self.create_repo(db, ref : Repo::Ref, shard_id = nil, role : Repo::Role = :canonical)
    db.create_repo Repo.new(ref, shard_id, role)
  end

  def self.create_shard(db, name = "shard", qualifier = "", description = nil, categories : Array(String)? = nil, archived_at : Time? = nil)
    shard_id = db.create_shard Shard.new(name, qualifier, description, archived_at)

    if categories
      db.connection.exec <<-SQL % db.sql_array(categories), shard_id
        UPDATE
          shards
        SET
          categories = coalesce((SELECT array_agg(id) FROM categories WHERE slug = ANY(ARRAY[%s]::text[])), ARRAY[]::bigint[])
        WHERE
          id = $1
        SQL
    end

    shard_id
  end

  def self.create_release(db, shard_id = nil, version = "0.1.0", released_at = Time.utc,
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

  def self.create_dependency(db, release_id : Int64, name : String, spec : JSON::Any = JSON.parse("{}"), repo_id : Int64? = nil, scope = Dependency::Scope::RUNTIME)
    db.connection.exec <<-SQL, release_id, name, spec.to_json, repo_id, scope
        INSERT INTO dependencies
          (release_id, name, spec, repo_id, scope)
        VALUES
          ($1, $2, $3::jsonb, $4, $5)
        SQL
  end

  def self.build_tag(name, message = "tag #{name}", tagger = "mock tagger")
    tagger = Release::Signature.new(tagger, "", Time.utc.at_beginning_of_second) unless tagger.is_a?(Release::Signature)
    Release::Tag.new(name, message, tagger)
  end

  def self.build_commit(sha, time = Time.utc, author = "mock author", committer = "mock comitter", message = "commit #{sha}")
    author = Release::Signature.new(author, "", Time.utc.at_beginning_of_second) unless author.is_a?(Release::Signature)
    committer = Release::Signature.new(committer, "", Time.utc.at_beginning_of_second) unless committer.is_a?(Release::Signature)
    Release::Commit.new(sha, time.at_beginning_of_second, author, committer, message)
  end

  def self.build_revision_info(tag = "v0.0.0", hash = "12345678")
    Release::RevisionInfo.new Factory.build_tag(tag), Factory.build_commit(hash)
  end

  def self.create_category(db, slug, name = slug)
    db.create_category(Category.new(slug, name))
  end
end
