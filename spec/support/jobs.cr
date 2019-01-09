require "taskmaster/adapter/test"

Taskmaster.adapter = Taskmaster::Adapter::Test.new

Spec.before_each do
  Taskmaster.adapter.queued_tasks.clear
end

def find_queued_tasks(name)
  Taskmaster.adapter.queued_tasks.select do |task|
    task.name == name
  end
end

def enqueued_jobs
  Taskmaster.adapter.queued_tasks.map { |task| {task.name, task.arguments} }
end
