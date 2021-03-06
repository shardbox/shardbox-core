require "raven"

Raven.configure do |config|
  config.connect_timeout = 10.seconds

  config.current_environment = ENV["CRYSTAL_ENV"]? || "development"

  if env_var = ENV["SENTRY_DSN_VAR"]?
    config.dsn = ENV[env_var]
  end
end
