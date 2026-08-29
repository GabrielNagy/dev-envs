# frozen_string_literal: true

require_relative "test_helper"

class CaddyTest < Minitest::Test
  include DevEnvTest

  SUBDOMAINS = { "" => true, "app" => true, "mcp" => false }.freeze
  KEY = "proj--feature--epxrnilj"

  def build_caddy(extra_config = {})
    @config = build_config(extra_config)
    project = build_project(@config, { "name" => "proj", "subdomains" => SUBDOMAINS })
    DevEnv::Caddy.new(@config, project: project)
  end

  def test_sites_use_matchers_and_split_guarded_and_open_hosts
    caddy = build_caddy
    caddy.define_singleton_method(:hash_password) { |_| "HASH" } # avoid needing the caddy binary
    caddy.write_site(KEY, "epxrnilj-proj.example.com", 4001, "pw")
    site = File.read(caddy.site_path(KEY))
    assert_equal File.join(@config.sites_dir, DevEnv::Caddy::ROUTES_DIR, "#{KEY}.caddy"), caddy.site_path(KEY)
    assert_includes site, "@proj__feature__epxrnilj_guarded host epxrnilj-proj.example.com app-epxrnilj-proj.example.com"
    assert_includes site, "basic_auth {\n\t\tdev HASH"
    assert_includes site, "@proj__feature__epxrnilj_open host mcp-epxrnilj-proj.example.com"
    refute_includes site.split("_open").last, "basic_auth"
  end

  def test_without_password_everything_is_open_on_the_same_hosts
    caddy = build_caddy
    caddy.define_singleton_method(:hash_password) { |_| "HASH" }
    caddy.write_site(KEY, "epxrnilj-proj.example.com", 4001, "pw")
    guarded_hosts = File.read(caddy.site_path(KEY)).scan(/host ([^\n]+)/).flatten.flat_map(&:split).sort

    caddy.write_site(KEY, "epxrnilj-proj.example.com", 4001, nil)
    site = File.read(caddy.site_path(KEY))
    refute_includes site, "basic_auth"
    # Auth is the only difference: the hostnames do not depend on it.
    assert_equal guarded_hosts, site.scan(/host ([^\n]+)/).flatten.flat_map(&:split).sort
  end

  def test_wildcard_site_covers_bare_and_folded_subdomain_hosts
    caddy = build_caddy
    caddy.ensure_wildcard_site
    caddy.write_site(KEY, "epxrnilj-proj.example.com", 4001, nil)

    wildcard = File.read(File.join(@config.sites_dir, DevEnv::Caddy::WILDCARD_SITE))
    assert_includes wildcard, "https://*.example.com {"
    assert_includes wildcard, "dns route53"
    assert_includes wildcard, "import #{File.join(@config.sites_dir, DevEnv::Caddy::ROUTES_DIR, '*.caddy')}"

    site = File.read(caddy.site_path(KEY))
    ["epxrnilj-proj.example.com", "app-epxrnilj-proj.example.com", "mcp-epxrnilj-proj.example.com"].each do |host|
      assert_includes site, host
      # Every served host sits one label under *.example.com, so the
      # wildcard certificate covers it.
      assert_match(/\A[a-z0-9-]+\.example\.com\z/, host)
    end
  end

  def test_delete_site_removes_the_route_file
    caddy = build_caddy
    caddy.write_site(KEY, "epxrnilj-proj.example.com", 4001, nil)
    assert_path_exists caddy.site_path(KEY)
    caddy.delete_site(KEY)
    refute_path_exists caddy.site_path(KEY)
  end

  def test_base_domain_change_is_refused
    caddy = build_caddy
    caddy.ensure_wildcard_site
    caddy.ensure_certificate_configuration! # same base_domain: fine

    changed = DevEnv::Caddy.new(
      DevEnv::Config.new(home: build_config("base_domain" => "other.net").home,
                         sites_dir: @config.sites_dir, caddyfile: @config.caddyfile),
    )
    refute changed.certificate_configuration_matches?
    error = assert_raises(DevEnv::Error) { changed.ensure_certificate_configuration! }
    assert_includes error.message, "dev-env down --all"
    assert_includes error.message, "dev-env setup"
  end

  def test_unmanaged_sites_are_left_alone
    caddy = build_caddy
    File.write(File.join(@config.sites_dir, "manual.wildcard.caddy"), "example.com {\n}\n")
    caddy.ensure_certificate_configuration!
  end
end
