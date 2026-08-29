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

    # Environments get unbounded randomized hostnames, so per-hostname
    # certificates would grow issuance without limit; one DNS-01 wildcard
    # certificate for the base domain is required instead.
    def acme_dns_provider
      provider = settings.fetch("acme_dns_provider", "").strip
      if provider.empty?
        raise Error, "acme_dns_provider is not set in #{path} — randomized hostnames need one " \
                     "wildcard certificate for the base domain, issued through a DNS-01 provider (e.g. \"route53\")"
      end
      provider
    end

    # Reserve a free loopback port and return the listening socket, so the
    # port stays claimed while an environment is prepared. The caller closes
    # it immediately before starting the service that binds the port.
    def reserve_port(reserved: [])
      low, high = settings.fetch("port_range", [4000, 4999])
      (low..high).to_a.shuffle.each do |port|
        next if reserved.include?(port)
        begin
          return TCPServer.new("127.0.0.1", port)
        rescue Errno::EADDRINUSE, Errno::EACCES
          next
        end
      end
      raise Error, "no free port available in #{low}..#{high}"
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
