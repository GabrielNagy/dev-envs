# frozen_string_literal: true

require_relative "test_helper"

class CLITest < Minitest::Test
  include DevEnvTest

  def setup
    @cli = DevEnv::CLI.new(config: build_config)
  end

  def test_help_prints_usage
    out, = capture_io { @cli.start(["help"]) }
    assert_includes out, "Usage: dev-env <command>"
  end

  def test_unknown_command_exits_nonzero
    exit_error = assert_raises(SystemExit) { capture_io { @cli.start(["bogus"]) } }
    assert_equal 1, exit_error.status
  end

  def test_errors_are_reported_and_exit_nonzero
    Dir.chdir(Dir.mktmpdir.tap { |d| @tmp_dirs << d }) do
      _, err = capture_io { assert_raises(SystemExit) { @cli.start(["init"]) } }
      assert_includes err, "not inside a git repository"
    end
  end

  def test_init_writes_starter_config_once
    repo = Dir.mktmpdir.tap { |d| @tmp_dirs << d }
    system("git", "init", "-q", repo)
    Dir.chdir(repo) do
      capture_io { @cli.start(["init"]) }
      settings = JSON.parse(File.read(".dev-env.json"))
      assert_equal File.basename(repo), settings["name"]
      assert settings.dig("commands", "server")

      _, err = capture_io { assert_raises(SystemExit) { DevEnv::CLI.new(config: build_config).start(["init"]) } }
      assert_includes err, "already exists"
    end
  end

  def test_list_with_no_environments
    out, = capture_io { @cli.start(["list"]) }
    assert_includes out, "No environments."
  end
end
