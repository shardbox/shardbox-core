struct Shardbox::GitHubAPI
  property mock_owner_info : Hash(String, JSON::Any)?

  def fetch_owner_info(login : String)
    if mock = mock_owner_info
      return mock
    else
      previous_def
    end
  end
end

struct Service::CreateOwner
  property skip_owner_info = false

  def fetch_owner_info(owner)
    unless skip_owner_info
      previous_def
    end
  end
end
