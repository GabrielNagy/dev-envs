# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  include DevEnvTest

  def test_default_home_is_xdg_config_directory
    original = ENV.delete("DEV_ENV_HOME")
    assert_equal File.expand_path("~/.config/dev-envs"), DevEnv::Config.new.home
  ensure
    ENV["DEV_ENV_HOME"] = original if original
  end

  def test_missing_config_file_raises
    config = DevEnv::Config.new(home: Dir.mktmpdir.tap { |d| (@tmp_dirs ||= []) << d })
    assert_raises(DevEnv::Error) { config.base_domain }
  end

  def test_settings_and_defaults
    config = build_config
    assert_equal "example.com", config.base_domain
    assert_equal "dev", config.basic_auth_user
    assert_equal "route53", config.acme_dns_provider
    assert_equal File.join(config.home, "envs"), config.state_dir
  end

  def test_project_settings_are_looked_up_by_expanded_repository_root
    root = Dir.mktmpdir.tap { |dir| (@tmp_dirs ||= []) << dir }
    equivalent_root = File.join(root, "..", File.basename(root))
    config = build_config("projects" => { equivalent_root => { "name" => "global-project" } })

    assert_equal({ "name" => "global-project" }, config.project_settings(root))
    assert_nil config.project_settings("/somewhere/else")
  end

  def test_projects_must_be_an_object
    config = build_config("projects" => [])

    error = assert_raises(DevEnv::Error) { config.project_settings("/repo") }
    assert_includes error.message, "must be an object"
  end

  def test_acme_dns_provider_is_required
    error = assert_raises(DevEnv::Error) { build_config("acme_dns_provider" => "").acme_dns_provider }
    assert_includes error.message, "acme_dns_provider"
    assert_raises(DevEnv::Error) { build_config("acme_dns_provider" => "  ").acme_dns_provider }
  end

  def test_reserve_port_returns_an_open_socket_and_skips_reserved_and_bound_ports
    config = build_config("port_range" => [41_000, 41_002])
    bound = TCPServer.new("127.0.0.1", 41_000)

    reservation = config.reserve_port(reserved: [41_001])
    assert_equal 41_002, reservation.addr[1]
    # The reservation itself holds the port until closed.
    assert_raises(Errno::EADDRINUSE) { TCPServer.new("127.0.0.1", 41_002) }
    assert_raises(DevEnv::Error) { config.reserve_port(reserved: [41_001]) }

    reservation.close
    config.reserve_port(reserved: [41_001]).close
  ensure
    bound&.close
  end
end
