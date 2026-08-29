# frozen_string_literal: true

module DevEnv
  # Machine-local configuration (config.json) and the directory layout
  # underneath the dev-env home.
  class Config
    attr_reader :home, :sites_dir, :caddyfile

    def initialize(home: ENV.fetch("DEV_ENV_HOME", File.expand_path("~/dev-envs")),
                   sites_dir: ENV.fetch("DEV_ENV_SITES_DIR", "/etc/caddy/sites"),
                   caddyfile: ENV.fetch("DEV_ENV_CADDYFILE", "/etc/caddy/Caddyfile"))
      @home = home
      @sites_dir = sites_dir
      @caddyfile = caddyfile
    end

    def path       = File.join(home, "config.json")
    def state_dir  = File.join(home, "envs")
    def dump_dir   = File.join(home, "dumps")
    def run_dir    = File.join(home, "run")
    def secret_dir = File.join(home, "secrets")
    def unit_path  = File.expand_path("~/.config/systemd/user/dev-env@.service")

    def exist? = File.exist?(path)

    def [](key) = settings[key]

    def base_domain     = settings["base_domain"]
    def basic_auth_user = settings.fetch("basic_auth_user", "dev")
    def pool_size       = settings.fetch("pool_size", 3)

    def wildcard_certificates? = !settings.fetch("acme_dns_provider", "").strip.empty?
    def acme_dns_provider      = settings.fetch("acme_dns_provider", "").strip

    def free_port(reserved: [])
      low, high = settings.fetch("port_range", [4000, 4999])
      (low..high).to_a.shuffle.find { |port| !reserved.include?(port) && !port_taken?(port) } ||
        raise(Error, "no free port available in #{low}..#{high}")
    end

    def port_taken?(port)
      TCPServer.new("127.0.0.1", port).close
      false
    rescue Errno::EADDRINUSE, Errno::EACCES
      true
    end

    private

    def settings
      @settings ||= begin
        raise Error, "no #{path} — run: dev-env setup" unless exist?
        JSON.parse(File.read(path))
      end
    end
  end
end
