# frozen_string_literal: true

module DevEnv
  # Caddy site management: one machine-wide DNS-01 wildcard certificate, and
  # the per-environment route files imported into it.
  class Caddy
    include Util

    WILDCARD_SITE = "_dev-env.wildcard.caddy"
    ROUTES_DIR = "_dev-env-routes"

    def initialize(config, project: nil)
      @config = config
      @project = project
    end

    def site_path(key) = File.join(routes_dir, "#{key}.caddy")

    def write_site(key, domain, port, password)
      auth = password ? "\n\tbasic_auth {\n\t\t#{@config.basic_auth_user} #{hash_password(password)}\n\t}" : ""
      guarded, open = @project.subdomains.partition { |sub| password && sub["auth"] }
      blocks = []
      blocks << site_block(key, "guarded", @project.hosts_for(domain, guarded), "reverse_proxy 127.0.0.1:#{port}#{auth}") if guarded.any?
      blocks << site_block(key, "open", @project.hosts_for(domain, open), "reverse_proxy 127.0.0.1:#{port}") if open.any?
      FileUtils.mkdir_p(routes_dir)
      File.write(site_path(key), "# Managed by dev-env — regenerated on `up`, removed on `down`.\n" + blocks.join("\n"))
    end

    def ensure_wildcard_site
      FileUtils.mkdir_p(routes_dir)
      File.write(wildcard_site_path, <<~CADDY)
        # Managed by dev-env — one wildcard site covering every project and environment.
        https://*.#{@config.base_domain} {
          tls {
            dns #{@config.acme_dns_provider}
          }
          import #{routes_dir}/*.caddy
        }
      CADDY
    end

    # base_domain is a setup-time choice; flipping it while managed sites
    # exist would strand certificates and hostnames.
    def certificate_configuration_matches?
      return true unless File.file?(wildcard_site_path)
      return true unless File.open(wildcard_site_path, &:gets).to_s.start_with?("# Managed by dev-env")

      File.read(wildcard_site_path).include?("https://*.#{@config.base_domain} {")
    end

    def ensure_certificate_configuration!
      return if certificate_configuration_matches?

      raise Error, "configured base_domain does not match the managed wildcard Caddy site. Run " \
                   "`dev-env down --all`, then `dev-env setup` to apply the new base_domain"
    end

    # Validate first: reloading a broken configuration would take every
    # environment down at once.
    def reload
      run("caddy", "validate", "--config", @config.caddyfile, quiet: true)
      run("caddy", "reload", "--config", @config.caddyfile, quiet: true)
    end

    def delete_site(key) = FileUtils.rm_f(site_path(key))

    def hash_password(password)
      hash = capture("caddy", "hash-password", "--plaintext", password)
      raise Error, "caddy hash-password failed" if hash.empty?
      hash
    end

    def caddyfile_content
      <<~CADDY
        # Managed by dev-env — wildcard and environment routes live under #{@config.sites_dir}
        #
        # default_bind pins Caddy to the public address. A wildcard bind can fail
        # with EADDRINUSE when something else (tailscaled, for one) already holds :443
        # on another interface.
        {
          email #{@config['acme_email'].to_s}
          default_bind #{@config['bind_ip'].to_s}
        }

        import #{@config.sites_dir}/*.caddy
      CADDY
    end

    private

    def routes_dir = File.join(@config.sites_dir, ROUTES_DIR)
    def wildcard_site_path = File.join(@config.sites_dir, WILDCARD_SITE)

    # The site file is imported into the machine-wide wildcard site, so it
    # holds matcher + handle pairs rather than a top-level site block.
    def site_block(key, part, hosts, body)
      matcher = "#{key.tr('-', '_')}_#{part}"
      "@#{matcher} host #{hosts.join(' ')}\nhandle @#{matcher} {\n\t#{body}\n}\n"
    end
  end
end
