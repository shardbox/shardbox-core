module Shardbox
  Log         = ::Log.for(self)
  ActivityLog = Log.for("activity")
end

class LogActivity
  DB.mapping(
    id: Int64,
    event: String,
    repo_id: Int64?,
    shard_id: Int64?,
    metadata: JSON::Any,
    created_at: Time,
  )
end
