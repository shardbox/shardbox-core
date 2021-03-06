require "git"
require "../../../release"
require "../../git/repo"

class Shards::GitResolver
  def revision_info(version : Shards::GitHeadRef | Shards::Version)
    update_local_cache

    repo = Git::Repo.open(local_path)

    case version
    when GitHeadRef
      ref = repo.ref(version.to_git_ref)
    when Version
      ref = git_ref(version)
      ref = repo.ref?(ref.to_git_ref)

      raise "Can't find tag #{version}" unless ref
    else
      raise "unreachable"
    end

    # Resolve symbolic references
    ref = ref.resolve

    target = ref.target
    if target.is_a?(Git::Tag)
      target = repo.lookup_tag(target.target_id)
    end

    case target
    when Git::Tag::Annotation
      # annotated tag
      tag = target
      commit = repo.lookup_commit(tag.target_oid)
      tag_info = Release::Tag.new(tag.name, tag.message.strip, signature(tag.tagger))
    when Git::Commit
      # lightweight tag
      commit = target
      tag_info = nil
    else
      raise "Unexpected target type #{target.class}"
    end

    commit_info = Release::Commit.new(commit.sha, commit.time, signature(commit.author), signature(commit.committer), commit.message.strip)

    Release::RevisionInfo.new tag_info, commit_info
  end

  private def signature(signature)
    Release::Signature.new(signature.name, signature.email, signature.time)
  end

  def read_spec!(version)
    if version.value == "HEAD"
      version = latest_version_for_ref(nil)
      raise Shards::Error.new("No version for HEAD") unless version
    end

    read_spec(version)
  end

  def fetch_file(version, path)
    # Tree#path is not yet implemented in libgit2.cr, falling back to CLI
    update_local_cache
    if version.value == "HEAD"
      ref = Shards::GitHeadRef.new
    else
      ref = git_ref(version)
    end

    if file_exists?(ref, path)
      capture("git show #{ref.to_git_ref}:#{path}")
    end
  end

  def repo_stats(version)
    tree = tree(version)
    file_count = tree.size_recursive
  end

  def tree(version)
    update_local_cache

    repo = Git::Repo.open(local_path)

    repo.lookup_tree(version)
  end
end
