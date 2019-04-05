class Git::Repository
  def ref?(name : String)
    if 0 == LibGit.reference_lookup(out ref, @value, name)
      Reference.new(ref)
    end
  end
end
