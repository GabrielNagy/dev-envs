# frozen_string_literal: true

require_relative "test_helper"

class SystemdTest < Minitest::Test
  include DevEnvTest

  def test_unit_name_uses_the_port_qualified_runtime_key
    systemd = DevEnv::Systemd.new(unit_path: "/tmp/x", env_dir: "/e", run_dir: "/r")
    assert_equal "dev-env@sample--dev-env-support--4593.service", systemd.unit("sample--dev-env-support--4593")
  end

  def test_install_writes_the_template_unit
    dir = Dir.mktmpdir.tap { |d| (@tmp_dirs ||= []) << d }
    unit_path = File.join(dir, "dev-env@.service")
    systemd = DevEnv::Systemd.new(unit_path: unit_path, env_dir: "/home/u/envs", run_dir: "/home/u/run")

    refute systemd.installed?
    systemd.define_singleton_method(:systemctl) { |*| true }
    systemd.install
    assert systemd.installed?

    unit = File.read(unit_path)
    assert_includes unit, "EnvironmentFile=/home/u/envs/%i.env"
    assert_includes unit, "ExecStart=/home/u/run/%i.sh"
    assert_includes unit, "WantedBy=default.target"
    refute_includes unit, "KillMode=mixed"
    refute_includes unit, ".overmind.sock"
  end

  def test_process_manager_configures_overmind_per_instance
    dir = Dir.mktmpdir.tap { |d| (@tmp_dirs ||= []) << d }
    unit_path = File.join(dir, "dev-env@.service")
    systemd = DevEnv::Systemd.new(unit_path: unit_path, env_dir: "/home/u/envs", run_dir: "/home/u/run")
    reloads = 0
    systemd.define_singleton_method(:systemctl) { |*| reloads += 1 }

    systemd.configure_process_manager("proj--feature--4001", "overmind")
    override = File.join(dir, "dev-env@proj--feature--4001.service.d", "dev-env-overmind.conf")
    assert_path_exists override
    assert_includes File.read(override), "KillMode=mixed"
    assert_includes File.read(override), '.overmind.sock'
    assert_equal 1, reloads

    systemd.configure_process_manager("proj--feature--4001", "overmind")
    assert_equal 1, reloads

    systemd.configure_process_manager("proj--feature--4001", "foreman")
    refute_path_exists override
    assert_equal 2, reloads
  end
end
