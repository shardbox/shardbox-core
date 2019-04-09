require "raven"

Raven.configure do |config|
  config.connect_timeout = 10.seconds
  config.current_environment = "production"
end
