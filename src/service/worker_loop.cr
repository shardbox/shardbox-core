require "../db"

# This service runs in the background and schedules commands.
struct Service::WorkerLoop
  getter sync_interval = 60
  getter metrics_schedule = 4 # hour of day

  getter? running : Bool = false

  @notify_connection : PG::ListenConnection?

  def initialize
    @channel = Channel(String).new
    @processes = [] of Process
  end

  def stop
    return unless running?

    puts "Shutting down."
    @running = false

    @notify_connection.try &.close

    @processes.each do |process|
      process.kill(Signal::INT) unless process.terminated?
    end

    @channel.send "shutdown"
  end

  def perform
    last_repo_sync = ShardsDB.connect do |db|
      db.last_repo_sync
    end

    p! last_repo_sync
    unless last_repo_sync
      last_repo_sync = Time.utc - sync_interval.minutes
    end

    @notify_connection = listen_for_notifications

    scheduled(last_repo_sync) do
      execute("sync_repos")

      last_metrics_calc = ShardsDB.connect do |db|
        db.last_metrics_calc
      end

      puts "metrics last performed at #{last_metrics_calc}"
      p! Time.utc.at_beginning_of_day + metrics_schedule.hours - 24.hours
      unless last_metrics_calc && last_metrics_calc > Time.utc.at_beginning_of_day + metrics_schedule.hours - 24.hours
        execute("update_metrics")
      end
    end
  end

  def scheduled(scheduled_time : Time)
    @running = true

    while running?
      scheduled_time = scheduled_time + sync_interval.minutes

      wait_seconds = scheduled_time - Time.utc
      if wait_seconds < Time::Span.zero
        wait_seconds = 0
        scheduled_time = Time.utc
      end

      puts "Next sync run at #{scheduled_time} (triggers in #{wait_seconds} seconds)..."
      sleep wait_seconds

      yield
    end
  end

  def execute(action)
    Process.run(PROGRAM_NAME, [action], output: :inherit, error: :inherit)
  end

  def listen_for_notifications
    ShardsDB.listen_for_jobs do |notification|
      if notification.payload == "import_catalog"
        execute("import_catalog")
      else
        puts "Received unrecognized notification: #{notification.payload}"
      end
    end
  end
end
