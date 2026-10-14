# frozen_string_literal: true

require_relative "test_helper"

class AutomationTest < Minitest::Test
  include DevEnvTest

  def setup
    @config = build_config
    @repo = File.join(@config.home, "repo")
    @tree = File.join(@config.home, "tree")
    @branch = "a" * 39 + "/tail"
    system("git", "init", "-q", "-b", "main", @repo, exception: true)
    system("git", "-C", @repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit",
           "-q", "--allow-empty", "-m", "initial", exception: true)
    system("git", "-C", @repo, "worktree", "add", "-q", "-b", @branch, @tree, exception: true)
    @bin = File.join(@config.home, "bin")
    FileUtils.mkdir_p(@bin)
    File.write(File.join(@bin, "systemctl"), "#!/bin/sh\necho active\n")
    File.chmod(0o755, File.join(@bin, "systemctl"))
  end

  def cli(*args, cwd: @tree)
    out, err, status = Open3.capture3({ "DEV_ENV_HOME" => @config.home, "PATH" => "#{@bin}:#{ENV['PATH']}" },
                                     RbConfig.ruby, File.expand_path("../bin/dev-env", __dir__), *args,
                                     chdir: cwd)
    assert_empty err
    refute_includes out, "secret-output"
    [JSON.parse(out), status.exitstatus]
  end

  def test_checkout_inspection_supports_both_config_sources_and_boundary_branch
    assert_equal({ "version" => 1, "configured" => false }, cli("inspect", "--json").first)
    assert_equal({ "version" => 1, "configured" => false }, cli("inspect", "--json", cwd: @config.home).first)
    config = JSON.parse(File.read(@config.path))
    config["projects"] = { @repo => { "name" => "machine-project" } }
    File.write(@config.path, JSON.generate(config))
    result, code = cli("inspect", "--json")
    assert_equal 0, code
    assert_equal "machine-project", result["project"]
    assert_equal @repo, result["project_root"]
    assert_equal @branch, result["branch"]
    assert_equal true, result["linked"]
    assert_nil result["environment"]
    assert_equal false, cli("inspect", "--json", cwd: @repo).first["linked"]
    File.write(File.join(@tree, ".dev-env.json"), JSON.generate({ "name" => "local-project" }))
    assert_equal "local-project", cli("inspect", "--json").first["project"]
    project = Dir.chdir(@tree) { DevEnv::Project.load(@config) }
    # Independent expected value: the separator at position 40 disappears.
    assert_equal "local-project--#{'a' * 39}--a1b2c3d4", project.key_for(@branch, "a1b2c3d4")
  end

  def test_inspection_waits_for_project_command_and_does_not_adopt_incomplete_state
    store = DevEnv::Store.new(state_dir: @config.state_dir, run_dir: @config.run_dir, secret_dir: @config.secret_dir)
    key = "example--#{'a' * 39}--a1b2c3d4"
    state = { "id" => "a1b2c3d4", "key" => key, "project" => "example", "project_root" => @repo,
              "branch" => @branch, "worktree" => @tree, "worktree_owned" => false,
              "domain" => "a1b2c3d4-example.example.com", "provisioned" => true,
              "readiness_command" => "echo secret-output; echo secret-output >&2; test -f ready || { touch ready; exit 1; }" }
    store.save(key, state)
    store.write_env(key, {})
    result, code = cli("inspect", "a1b2c3d4", "--json", "--wait", "3")
    assert_equal 0, code
    assert_equal true, result.dig("environment", "ready")
    assert_equal "https://a1b2c3d4-example.example.com/", result.dig("environment", "url")
    refute result["environment"].key?("readiness_command")
    state["provisioned"] = false
    store.save(key, state)
    assert_equal false, cli("inspect", "a1b2c3d4", "--json").first.dig("environment", "ready")
    state.merge!("provisioned" => true, "readiness_command" => "exit 1")
    store.save(key, state)
    assert_equal false, cli("inspect", "a1b2c3d4", "--json").first.dig("environment", "ready")
  end

  def test_absence_is_explicit_and_invalid_or_broad_operations_fail_safely
    assert_nil cli("inspect", "a1b2c3d4", "--json").first["environment"]
    result, code = cli("down", "a1b2c3d4", "--keep-worktree", "--json")
    assert_equal 0, code
    assert_equal({ "version" => 1, "id" => "a1b2c3d4", "status" => "absent" }, result)
    [["down", "--all"], ["down", "a1b2c3d4"], ["inspect", "secret-output"]].each do |args|
      result, code = cli(*args, "--json")
      assert_equal 1, code
      assert_equal({ "version" => 1, "error" => "operation-failed" }, result)
    end
  end
end
