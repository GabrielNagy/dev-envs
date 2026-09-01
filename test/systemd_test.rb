# frozen_string_literal: true

require_relative "test_helper"

class SystemdTest < Minitest::Test
  include DevEnvTest

  def build_systemd
    dir = Dir.mktmpdir.tap { |d| (@tmp_dirs ||= []) << d }
    @unit_path = File.join(dir, "dev-env@.service")
    DevEnv::Systemd.new(unit_path: @unit_path, env_dir: "/home/u/envs", run_dir: "/home/u/run")
  end

  def test_install_writes_the_template_unit_named_by_the_artifact_key
    systemd = build_systemd
    key = "sample--worktree-silver-cloud-2a0f--epxrnilj"
    assert_equal "dev-env@#{key}.service", systemd.unit(key)

    refute systemd.installed?
    systemd.define_singleton_method(:systemctl) { |*| true }
    systemd.install
    assert systemd.installed?

    unit = File.read(@unit_path)
    assert_includes unit, "EnvironmentFile=/home/u/envs/%i.env"
    assert_includes unit, "ExecStart=/home/u/run/%i.sh"
    assert_includes unit, "WantedBy=default.target"
    refute_includes unit, "KillMode=mixed"
  end

  def test_process_manager_configures_overmind_per_instance
    systemd = build_systemd
    reloads = 0
    systemd.define_singleton_method(:systemctl) { |*| reloads += 1 }

    systemd.configure_process_manager("proj--feature--epxrnilj", "overmind")
    override = File.join(File.dirname(@unit_path),
                         "dev-env@proj--feature--epxrnilj.service.d", "dev-env-overmind.conf")
    assert_path_exists override
    assert_includes File.read(override), "KillMode=mixed"
    assert_includes File.read(override), ".overmind.sock"
    assert_equal 1, reloads

    systemd.configure_process_manager("proj--feature--epxrnilj", "overmind")
    assert_equal 1, reloads

    systemd.configure_process_manager("proj--feature--epxrnilj", "foreman")
    refute_path_exists override
    assert_equal 2, reloads
  end
end
