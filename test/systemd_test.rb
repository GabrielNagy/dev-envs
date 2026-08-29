# frozen_string_literal: true

require_relative "test_helper"

class SystemdTest < Minitest::Test
  include DevEnvTest

  def test_unit_name
    systemd = DevEnv::Systemd.new(unit_path: "/tmp/x", env_dir: "/e", run_dir: "/r")
    assert_equal "dev-env@proj-dev1.service", systemd.unit("proj-dev1")
  end

  def test_install_writes_the_template_unit
    dir = Dir.mktmpdir.tap { |d| (@tmp_dirs ||= []) << d }
    unit_path = File.join(dir, "dev-env@.service")
    systemd = DevEnv::Systemd.new(unit_path: unit_path, env_dir: "/home/u/envs", run_dir: "/home/u/run")

    refute systemd.installed?
    systemd.define_singleton_method(:systemctl) { |*| true } # skip the real daemon-reload
    systemd.install
    assert systemd.installed?

    unit = File.read(unit_path)
    assert_includes unit, "EnvironmentFile=/home/u/envs/%i.env"
    assert_includes unit, "ExecStart=/home/u/run/%i.sh"
    assert_includes unit, "WantedBy=default.target"
  end
end
