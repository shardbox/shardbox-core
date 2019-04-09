require "raven"

Raven.configure do |config|
  config.current_environment = "dev"
  config.environments = ["production"]
end
