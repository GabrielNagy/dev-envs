# frozen_string_literal: true

module DevEnv
  # Caddy site management: per-environment sites, parked placeholders that
  # keep certificates renewing while a slot is free, the per-project wildcard
  # site, and the safety checks around changing certificate mode.
  class Caddy
    include Util

    def initialize(config, project: nil)
      @config = config
      @project = project
    end

    def site_path(key)
      File.join(@config.wildcard_certificates? ? project_sites_dir : @config.sites_dir, "#{key}.caddy")
    end

    def write_site(key, domain, port, password)
      auth = password ? "\n\tbasic_auth {\n\t\t#{@config.basic_auth_user} #{hash_password(password)}\n\t}" : ""
      guarded, open = @project.subdomains.partition { |sub| password && sub["auth"] }
      blocks = []
      blocks << site_block(key, "guarded", @project.hosts_for(domain, guarded), "reverse_proxy 127.0.0.1:#{port}#{auth}") if guarded.any?
      blocks << site_block(key, "open", @project.hosts_for(domain, open), "reverse_proxy 127.0.0.1:#{port}") if open.any?
      write_site_file(key, "# Managed by dev-env — regenerated on `up`, parked on `down`.\n", blocks)
    end

    def write_parking_site(key, slot, domain = @project.domain_for(slot))
      respond = %(respond "#{@project.name}/#{slot} is free — claim it with: dev-env up <branch> --slot #{slot}" 200)
      write_site_file(key, <<~HEADER, [site_block(key, "parked", @project.hosts_for(domain), respond)])
        # Managed by dev-env — placeholder so this slot's certificates stay renewed
        # while it is free. Replaced when an environment claims the slot.
      HEADER
    end

    def ensure_wildcard_site
      return unless @config.wildcard_certificates?

      FileUtils.mkdir_p(project_sites_dir)
      File.write(File.join(@config.sites_dir, "#{@project.name}.wildcard.caddy"), <<~CADDY)
        # Managed by dev-env — one wildcard site for every slot in this project.
        https://*.#{@project.name}.#{@config.base_domain} {
          tls {
            dns #{@config.acme_dns_provider}
          }
          import #{project_sites_dir}/*.caddy
        }
      CADDY
    end

    # Certificate mode and base_domain are setup-time choices; flipping either
    # while managed sites exist would strand certificates and hostnames.
    def ensure_certificate_configuration!
      wildcard_sites = managed_sites("*.wildcard.caddy")
      exact_sites = managed_sites("*.caddy") - wildcard_sites
      conflicting = @config.wildcard_certificates? ? exact_sites : wildcard_sites
      unless conflicting.empty?
        raise Error, "certificate mode changed while managed Caddy sites exist. Restore the previous " \
                     "acme_dns_provider, tear down active environments, then remove the managed sites " \
                     "under #{@config.sites_dir} before applying this change"
      end

      return unless @config.wildcard_certificates?

      mismatched = wildcard_sites.reject do |path|
        name = File.basename(path).delete_suffix(".wildcard.caddy")
        File.read(path).include?("https://*.#{name}.#{@config.base_domain} {")
      end
      return if mismatched.empty?

      raise Error, "base_domain changed while wildcard Caddy sites exist. Restore the previous base_domain, " \
                   "tear down active environments, then remove the managed sites under #{@config.sites_dir} " \
                   "before applying this change"
    end

    def reload = run("caddy", "reload", "--config", @config.caddyfile, quiet: true)

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

    # With wildcard certificates the site file is imported into the project's
    # wildcard site, so it holds matcher + handle pairs; otherwise it is a
    # top-level site block of its own.
    def site_block(key, part, hosts, body)
      if @config.wildcard_certificates?
        matcher = "#{key.tr('-', '_')}_#{part}"
        "@#{matcher} host #{hosts.join(' ')}\nhandle @#{matcher} {\n\t#{body}\n}\n"
      else
        "#{hosts.join(', ')} {\n\t#{body}\n}\n"
      end
    end

    def write_site_file(key, header, blocks)
      FileUtils.mkdir_p(File.dirname(site_path(key)))
      File.write(site_path(key), header + blocks.join("\n"))
    end
  end
end
