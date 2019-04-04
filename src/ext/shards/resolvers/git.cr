require "../../../release"
require "git"

class Shards::GitResolver
  def revision_info(version)
    update_local_cache

    repo = Git::Repo.open(local_path)
    ref = repo.ref("refs/tags/v#{version}")

    case target = ref.target
    when Git::Tag
      # annotated tag
      tag = target
      commit = repo.lookup_commit(tag.target_oid)
      tag_info = Release::Tag.new(tag.name, tag.message, signature(tag.tagger))
    when Git::Commit
      # lightweight tag
      commit = target
      tag_info = nil
    else
      raise "Unexpected target type #{target.class}"
    end

    commit_info = Release::Commit.new(commit.sha, commit.time, signature(commit.author), signature(commit.committer), commit.message)

    Release::RevisionInfo.new tag_info, commit_info
  end

  private def signature(signature)
    Release::Signature.new(signature.name, signature.email, signature.time)
  end
end
