# frozen_string_literal: true

require "fileutils"
require "json"
require "net/http"
require "optparse"
require "securerandom"
require "shellwords"
require "socket"
require "time"

# Run project branches on this box, each reachable over HTTPS. An environment
# is created on demand for one branch: a git worktree, a database (postgres
# unless the project declares another engine), a loopback port and a systemd
# user unit, with Caddy terminating TLS in front
# through one wildcard certificate for the base domain. See README.md.
module DevEnv
  # Every user-facing failure; the CLI prints it and exits 1.
  class Error < StandardError; end
end

require_relative "dev_env/util"
require_relative "dev_env/config"
require_relative "dev_env/secrets"
require_relative "dev_env/store"
require_relative "dev_env/database"
require_relative "dev_env/project"
require_relative "dev_env/caddy"
require_relative "dev_env/systemd"
require_relative "dev_env/worktrees"
require_relative "dev_env/cli"
