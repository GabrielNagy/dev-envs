# frozen_string_literal: true

module DevEnv
  # Caddy site management: the per-project wildcard site holding one DNS-01
  # certificate, and the per-environment route files imported into it.
  class Caddy
    include Util

    def initialize(config, project: nil)
      @config = config
      @project = project
    end

    def site_path(key) = File.join(project_sites_dir, "#{key}.caddy")

    def write_site(key, domain, port, password)
      auth = password ? "\n\tbasic_auth {\n\t\t#{@config.basic_auth_user} #{hash_password(password)}\n\t}" : ""
      guarded, open = @project.subdomains.partition { |sub| password && sub["auth"] }
      blocks = []
      blocks << site_block(key, "guarded", @project.hosts_for(domain, guarded), "reverse_proxy 127.0.0.1:#{port}#{auth}") if guarded.any?
      blocks << site_block(key, "open", @project.hosts_for(domain, open), "reverse_proxy 127.0.0.1:#{port}") if open.any?
      FileUtils.mkdir_p(project_sites_dir)
      File.write(site_path(key), "# Managed by dev-env — regenerated on `up`, removed on `down`.\n" + blocks.join("\n"))
    end

    def ensure_wildcard_site
      FileUtils.mkdir_p(project_sites_dir)
      File.write(File.join(@config.sites_dir, "#{@project.name}.wildcard.caddy"), <<~CADDY)
        # Managed by dev-env — one wildcard site covering every environment in this project.
        https://*.#{@project.name}.#{@config.base_domain} {
          tls {
            dns #{@config.acme_dns_provider}
          }
          import #{project_sites_dir}/*.caddy
        }
      CADDY
    end

    # base_domain is a setup-time choice; flipping it while managed sites
    # exist would strand certificates and hostnames.
    def ensure_certificate_configuration!
      mismatched = managed_sites("*.wildcard.caddy").reject do |path|
        name = File.basename(path).delete_suffix(".wildcard.caddy")
        File.read(path).include?("https://*.#{name}.#{@config.base_domain} {")
      end
      return if mismatched.empty?

      raise Error, "base_domain changed while wildcard Caddy sites exist. Restore the previous base_domain, " \
                   "tear down active environments, then remove the managed sites under #{@config.sites_dir} " \
                   "before applying this change"
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
        # Managed by dev-env — per-environment sites live in #{@config.sites_dir}/*.caddy
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

    def project_sites_dir = File.join(@config.sites_dir, @project.name)

    def managed_sites(pattern)
      Dir.glob(File.join(@config.sites_dir, pattern)).select do |path|
        File.file?(path) && File.open(path, &:gets).to_s.start_with?("# Managed by dev-env")
      end
    end

    # The site file is imported into the project's wildcard site, so it holds
    # matcher + handle pairs rather than a top-level site block.
    def site_block(key, part, hosts, body)
      matcher = "#{key.tr('-', '_')}_#{part}"
      "@#{matcher} host #{hosts.join(' ')}\nhandle @#{matcher} {\n\t#{body}\n}\n"
    end
  end
end
