# frozen_string_literal: true

require_relative "test_helper"

class CaddyTest < Minitest::Test
  include DevEnvTest

  SUBDOMAINS = { "" => true, "app" => true, "mcp" => false }.freeze

  def build_caddy(extra_config = {})
    @config = build_config(extra_config)
    project = build_project(@config, { "name" => "proj", "subdomains" => SUBDOMAINS })
    DevEnv::Caddy.new(@config, project: project)
  end

  def test_exact_mode_splits_guarded_and_open_hosts
    caddy = build_caddy
    caddy.define_singleton_method(:hash_password) { |_| "HASH" } # avoid needing the caddy binary
    caddy.write_site("proj-dev1", "dev1.proj.example.com", 4001, "pw")
    site = File.read(caddy.site_path("proj-dev1"))
    assert_includes site, "dev1.proj.example.com, app.dev1.proj.example.com {"
    assert_includes site, "basic_auth {\n\t\tdev HASH"
    assert_includes site, "mcp.dev1.proj.example.com {\n\treverse_proxy 127.0.0.1:4001\n}"
    refute_includes site.split("mcp.").last, "basic_auth"
  end

  def test_without_password_everything_is_open
    caddy = build_caddy
    caddy.write_site("proj-dev1", "dev1.proj.example.com", 4001, nil)
    site = File.read(caddy.site_path("proj-dev1"))
    refute_includes site, "basic_auth"
    assert_includes site, "mcp.dev1.proj.example.com {"
  end

  def test_wildcard_mode_uses_matchers_and_folded_labels
    caddy = build_caddy("acme_dns_provider" => "route53")
    caddy.ensure_wildcard_site
    caddy.write_parking_site("proj-dev1", "dev1")

    wildcard = File.read(File.join(@config.sites_dir, "proj.wildcard.caddy"))
    assert_includes wildcard, "https://*.proj.example.com {"
    assert_includes wildcard, "dns route53"

    parked = File.read(caddy.site_path("proj-dev1"))
    assert_equal File.join(@config.sites_dir, "proj", "proj-dev1.caddy"), caddy.site_path("proj-dev1")
    assert_includes parked, "@proj_dev1_parked host dev1.proj.example.com app-dev1.proj.example.com mcp-dev1.proj.example.com"
    assert_includes parked, "proj/dev1 is free"
  end

  def test_certificate_mode_change_is_refused
    caddy = build_caddy
    caddy.write_site("proj-dev1", "dev1.proj.example.com", 4001, nil)
    caddy.ensure_certificate_configuration! # same mode: fine

    flipped = build_config("acme_dns_provider" => "route53")
    wildcard_caddy = DevEnv::Caddy.new(
      DevEnv::Config.new(home: flipped.home, sites_dir: @config.sites_dir, caddyfile: @config.caddyfile),
    )
    assert_raises(DevEnv::Error) { wildcard_caddy.ensure_certificate_configuration! }
  end

  def test_unmanaged_sites_are_left_alone
    caddy = build_caddy("acme_dns_provider" => "route53")
    File.write(File.join(@config.sites_dir, "manual.caddy"), "example.com {\n}\n")
    caddy.ensure_certificate_configuration!
  end
end
