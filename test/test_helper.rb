# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../lib/dev_env"

# Builds a throwaway machine config and project without touching the real
# ~/.config/dev-envs or /etc/caddy.
module DevEnvTest
  def build_config(extra = {})
    @tmp_dirs ||= []
    home = Dir.mktmpdir("dev-env-home")
    sites = Dir.mktmpdir("dev-env-sites")
    @tmp_dirs += [home, sites]
    settings = {
      "base_domain" => "example.com", "bind_ip" => "127.0.0.1",
      "port_range" => [41_000, 41_010],
      "acme_email" => "x@example.com", "acme_dns_provider" => "route53",
    }.merge(extra)
    File.write(File.join(home, "config.json"), JSON.generate(settings))
    DevEnv::Config.new(home: home, sites_dir: sites, caddyfile: File.join(sites, "Caddyfile"),
                       cache_dir: File.join(home, "cache"))
  end

  def build_project(config, settings = {}, root: "/repo")
    DevEnv::Project.new(config, root: root, settings: settings)
  end

  def teardown
    (@tmp_dirs || []).each { |dir| FileUtils.remove_entry(dir) }
    super
  end
end
