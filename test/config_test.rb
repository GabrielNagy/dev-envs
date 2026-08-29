# frozen_string_literal: true

require_relative "test_helper"

class ConfigTest < Minitest::Test
  include DevEnvTest

  def test_missing_config_file_raises
    config = DevEnv::Config.new(home: Dir.mktmpdir.tap { |d| (@tmp_dirs ||= []) << d })
    assert_raises(DevEnv::Error) { config.base_domain }
  end

  def test_settings_and_defaults
    config = build_config
    assert_equal "example.com", config.base_domain
    assert_equal "dev", config.basic_auth_user
    assert_equal 2, config.pool_size
    refute config.wildcard_certificates?
    assert build_config("acme_dns_provider" => "route53").wildcard_certificates?
    assert_equal File.join(config.home, "envs"), config.state_dir
  end

  def test_free_port_skips_reserved_and_bound_ports
    config = build_config("port_range" => [41_000, 41_002])
    server = TCPServer.new("127.0.0.1", 41_000)
    assert_equal 41_002, config.free_port(reserved: [41_001])
    assert_raises(DevEnv::Error) { config.free_port(reserved: [41_001, 41_002]) }
  ensure
    server&.close
  end
end
