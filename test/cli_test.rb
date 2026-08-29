# frozen_string_literal: true

require_relative "test_helper"

class CLITest < Minitest::Test
  include DevEnvTest

  def setup
    @config = build_config
    @cli = DevEnv::CLI.new(config: @config)
    FileUtils.mkdir_p([@config.state_dir, @config.run_dir, @config.secret_dir])
    @store = DevEnv::Store.new(state_dir: @config.state_dir, run_dir: @config.run_dir)
  end

  # Runs the block inside a git repository configured as project `name`, so
  # CLI commands can load the project the way they do in real use.
  def in_project(name = "proj", settings = {})
    repo = Dir.mktmpdir.tap { |d| @tmp_dirs << d }
    system("git", "init", "-q", repo)
    File.write(File.join(repo, ".dev-env.json"), JSON.generate({ "name" => name }.merge(settings)))
    Dir.chdir(repo) { yield }
  end

  def save_state(project:, branch:, port:, identifier:, **extra)
    key = "#{project}--#{DevEnv::Util.slugify(branch)}--#{port}"
    @store.save(key, {
      "key" => key, "project" => project, "branch" => branch, "identifier" => identifier,
      "domain" => "#{identifier}.#{project}.example.com", "port" => port,
      "database" => "dev_env_#{project}_#{port}_#{identifier}", "worktree" => "/nowhere/#{key}",
      "worktree_owned" => false, "basic_auth" => true, "process_manager" => nil,
    }.merge(extra))
    key
  end

  # Replaces the adapter's subprocesses so no test touches a real database
  # server; returns the list of dropped names.
  def stub_database_drops
    dropped = []
    real = @cli.method(:database_for)
    @cli.define_singleton_method(:database_for) do |state|
      real.call(state).tap do |db|
        db.define_singleton_method(:drop) { |name, **| dropped << name }
      end
    end
    dropped
  end

  # Runs enough of `up` to capture the state it would persist, while replacing
  # the database and build phases that need machine services.
  def up_state_for(settings, *auth_options)
    state = nil
    cli = DevEnv::CLI.new(config: @config)
    in_project("proj", settings) do
      system("git", "add", ".dev-env.json")
      system("git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "initial")
      system("git", "checkout", "-qb", "feature")

      cli.send(:systemd).define_singleton_method(:installed?) { true }
      database = Object.new
      database.define_singleton_method(:exists?) { |_| false }
      database.define_singleton_method(:create) { |_| true }
      cli.define_singleton_method(:database_for) { |_| database }
      cli.define_singleton_method(:build_environment) { |candidate, *| state = candidate }
      cli.define_singleton_method(:print_summary) { |_, total:| total }

      capture_io do
        cli.send(:cmd_up, ["feature", "--worktree", Dir.pwd, "--no-seed", *auth_options])
      end
    end
    state
  end

  def test_help_prints_usage
    out, = capture_io { @cli.start(["help"]) }
    assert_includes out, "Usage: dev-env <command>"
    assert_includes out, "up [branch]"
    refute_match(/slot/i, out)
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
      assert_equal false, settings["public"]

      _, err = capture_io { assert_raises(SystemExit) { DevEnv::CLI.new(config: build_config).start(["init"]) } }
      assert_includes err, "already exists"
    end
  end

  def test_list_with_no_environments
    out, = capture_io { @cli.start(["list"]) }
    assert_includes out, "No environments."
  end

  def test_list_shows_exactly_project_branch_port_status_url_for_any_number_of_environments
    5.times { |n| save_state(project: "proj", branch: "branch-#{n}", port: 4000 + n, identifier: "id#{n}aaaa") }
    @cli.send(:systemd).define_singleton_method(:status) { |_| "inactive" }

    out, = capture_io { @cli.start(["list"]) }
    lines = out.lines.map(&:chomp).reject(&:empty?)
    assert_equal %w[PROJECT BRANCH PORT STATUS URL], lines.first.split
    assert_equal 6, lines.length # header + one row per environment, no free-slot footer
    refute_match(/free/i, out)
    assert_includes out, "https://id0aaaa.proj.example.com"
  end

  def test_resolve_finds_state_by_exact_project_and_branch_despite_colliding_slugs
    slashed = save_state(project: "proj", branch: "feature/foo", port: 4001, identifier: "aaaaaaaa")
    dashed  = save_state(project: "proj", branch: "feature-foo", port: 4002, identifier: "bbbbbbbb")
    other   = save_state(project: "zed", branch: "feature/zed", port: 4003, identifier: "cccccccc")

    in_project do
      assert_equal slashed, @cli.send(:resolve, "feature/foo")
      assert_equal dashed, @cli.send(:resolve, "feature-foo")
      assert_equal other, @cli.send(:resolve, other), "a runtime key is accepted as-is"
      error = assert_raises(DevEnv::Error) { @cli.send(:resolve, "feature/zed") }
      assert_includes error.message, "no environment"
    end
  end

  def test_up_rejects_a_second_environment_for_the_same_project_and_branch
    save_state(project: "proj", branch: "feature", port: 4001, identifier: "aaaaaaaa")
    in_project do
      error = assert_raises(DevEnv::Error) { @cli.send(:cmd_up, ["feature"]) }
      assert_includes error.message, "already has an environment"
    end
  end

  def test_up_infers_the_branch_from_the_current_checkout_when_omitted
    save_state(project: "proj", branch: "feature", port: 4001, identifier: "aaaaaaaa")
    in_project do
      system("git", "checkout", "-q", "-b", "feature")
      error = assert_raises(DevEnv::Error) { @cli.send(:cmd_up, []) }
      assert_includes error.message, "already has an environment", "expected the checked-out branch to be inferred"
    end
  end

  def test_up_uses_the_project_public_default
    assert_equal true, up_state_for({})["basic_auth"]
    assert_equal false, up_state_for({ "public" => true })["basic_auth"]
  end

  def test_up_public_and_private_options_override_the_project_default
    assert_equal false, up_state_for({ "public" => false }, "--public")["basic_auth"]
    assert_equal true, up_state_for({ "public" => true }, "--private")["basic_auth"]
  end

  def test_id_validation_accepts_dns_labels_and_rejects_everything_else
    in_project do
      %w[pkliinp6 a a1 a-b 12345678 ab-cd-ef].each do |id|
        assert_equal id, @cli.send(:validate_identifier!, id)
      end
      ["Pkliinp6", "a.b", "toolong9x", "-ab", "ab-", "", "a_b", "päx"].each do |id|
        error = assert_raises(DevEnv::Error, "expected #{id.inspect} to be rejected") do
          @cli.send(:validate_identifier!, id)
        end
        assert_includes error.message, "not a usable identifier"
      end
    end
  end

  def test_identifier_collisions_are_scoped_to_the_project
    save_state(project: "proj", branch: "feature", port: 4001, identifier: "pkliinp6")
    save_state(project: "zed", branch: "other", port: 4002, identifier: "qqqqqqqq")

    in_project do
      error = assert_raises(DevEnv::Error) { @cli.send(:validate_identifier!, "pkliinp6") }
      assert_includes error.message, "already used by proj/feature"
      # Another project's identifier may be reused here.
      assert_equal "qqqqqqqq", @cli.send(:validate_identifier!, "qqqqqqqq")
    end
  end

  def test_generated_identifiers_retry_recorded_collisions
    save_state(project: "proj", branch: "feature", port: 4001, identifier: "aaaaaaaa")
    sequence = %w[aaaaaaaa bbbbbbbb]
    @cli.define_singleton_method(:random_identifier) { sequence.shift }
    in_project do
      assert_equal "bbbbbbbb", @cli.send(:generate_identifier)
      assert_empty sequence
    end
  end

  def test_up_summary_ends_with_the_total_duration
    key = save_state(project: "proj", branch: "feature", port: 4001, identifier: "aaaaaaaa")

    in_project do
      out, = capture_io { @cli.send(:print_summary, key, total: 65) }

      assert out.rstrip.end_with?("Total      [1m 05s]"), out
    end
  end

  def test_down_removes_state_caddy_route_and_password
    key = save_state(project: "proj", branch: "feature", port: 4001, identifier: "aaaaaaaa")
    secrets = DevEnv::Secrets.new(@config.secret_dir)
    secrets.password_for(key)

    in_project do
      route = @cli.send(:caddy).site_path(key)
      FileUtils.mkdir_p(File.dirname(route))
      File.write(route, "# Managed by dev-env\n")
      @cli.send(:caddy).define_singleton_method(:reload) { nil }
      @cli.send(:systemd).define_singleton_method(:systemctl) { |*| true }
      @cli.send(:systemd).define_singleton_method(:configure_process_manager) { |*| nil }
      dropped = stub_database_drops

      out, = capture_io { @cli.send(:cmd_down, ["feature"]) }

      refute @store.exist?(key)
      refute_path_exists route
      refute secrets.password?(key)
      assert_equal ["dev_env_proj_4001_aaaaaaaa"], dropped, "a record without a database list drops its one database"
      assert_includes out, "proj/feature removed"
      refute_match(/kept for reuse|parking/i, out)
    end
  end

  def test_down_infers_the_environment_from_the_current_worktree_when_omitted
    worktree = Dir.mktmpdir.tap { |d| @tmp_dirs << d }
    key = save_state(project: "proj", branch: "feature", port: 4001, identifier: "aaaaaaaa",
                     "worktree" => worktree)

    in_project do
      @cli.send(:caddy).define_singleton_method(:reload) { nil }
      @cli.send(:systemd).define_singleton_method(:systemctl) { |*| true }
      @cli.send(:systemd).define_singleton_method(:configure_process_manager) { |*| nil }
      stub_database_drops

      out, = capture_io { Dir.chdir(worktree) { @cli.send(:cmd_down, []) } }

      refute @store.exist?(key), "expected the environment to be inferred from the worktree"
      assert_includes out, "proj/feature removed"
    end
  end

  def test_down_without_argument_outside_a_worktree_fails_with_usage
    save_state(project: "proj", branch: "feature", port: 4001, identifier: "aaaaaaaa")
    in_project do
      error = assert_raises(DevEnv::Error) { @cli.send(:cmd_down, []) }
      assert_includes error.message, "Usage: dev-env down [branch]"
    end
  end

  def test_down_drops_every_recorded_database_with_the_recorded_adapter
    save_state(project: "proj", branch: "feature", port: 4001, identifier: "aaaaaaaa",
               "databases" => ["dev_env_proj_4001_aaaaaaaa", "dev_env_proj_4001_aaaaaaaa_data_science"],
               "database_settings" => { "adapter" => "mysql", "user" => "sample_dev" })

    in_project do
      @cli.send(:caddy).define_singleton_method(:reload) { nil }
      @cli.send(:systemd).define_singleton_method(:systemctl) { |*| true }
      @cli.send(:systemd).define_singleton_method(:configure_process_manager) { |*| nil }

      state = @store.load("proj--feature--4001")
      db = @cli.send(:database_for, state)
      assert_instance_of DevEnv::Database::MySQL, db, "the adapter comes from state, not the repository"

      dropped = stub_database_drops
      capture_io { @cli.send(:cmd_down, ["feature"]) }
      assert_equal ["dev_env_proj_4001_aaaaaaaa", "dev_env_proj_4001_aaaaaaaa_data_science"], dropped
    end
  end

  def test_down_runs_after_down_hooks_with_vars_and_keep_flags_and_survives_failures
    key = save_state(project: "proj", branch: "feature", port: 4001, identifier: "aaaaaaaa")

    in_project("proj", "after_down" => ["cleanup ${PORT} ${BRANCH}", "exit 1"]) do
      @cli.send(:caddy).define_singleton_method(:reload) { nil }
      @cli.send(:systemd).define_singleton_method(:systemctl) { |*| true }
      @cli.send(:systemd).define_singleton_method(:configure_process_manager) { |*| nil }
      stub_database_drops
      calls = []
      @cli.define_singleton_method(:run) do |*cmd, **kwargs|
        calls << [cmd.join(" "), kwargs]
        !cmd.join(" ").start_with?("exit") # the second hook fails
      end

      out, err = capture_io { @cli.send(:cmd_down, ["feature", "--keep-worktree"]) }

      hook, kwargs = calls.find { |command,| command == "cleanup 4001 feature" }
      assert hook, "expected the interpolated hook to run, got: #{calls.map(&:first)}"
      assert_equal "true", kwargs[:env]["DEV_ENV_KEEP_WORKTREE"]
      assert_equal "false", kwargs[:env]["DEV_ENV_KEEP_DATABASE"]
      assert_includes err.to_s + out, "after_down command failed"
      refute @store.exist?(key), "a failing hook must not abort down"
    end
  end

  def test_warm_rewrites_only_recorded_environments_of_the_current_project
    mine  = save_state(project: "proj", branch: "feature", port: 4001, identifier: "aaaaaaaa", "basic_auth" => false)
    other = save_state(project: "zed", branch: "other", port: 4002, identifier: "bbbbbbbb", "basic_auth" => false)

    in_project do
      @cli.send(:caddy).define_singleton_method(:reload) { nil }
      @cli.define_singleton_method(:capture) { |*| "200" } # curl always succeeds

      out, = capture_io { @cli.send(:cmd_warm, []) }

      assert_path_exists File.join(@config.sites_dir, "proj.wildcard.caddy")
      assert_path_exists File.join(@config.sites_dir, "proj", "#{mine}.caddy")
      refute_path_exists File.join(@config.sites_dir, "zed.wildcard.caddy")
      assert_empty Dir.glob(File.join(@config.sites_dir, "**", "#{other}.caddy"))
      assert_includes out, "Certificates warmed for proj"
    end
  end

  def test_creds_without_argument_enumerates_the_projects_recorded_environments
    key = save_state(project: "proj", branch: "feature", port: 4001, identifier: "aaaaaaaa")
    save_state(project: "zed", branch: "other", port: 4002, identifier: "bbbbbbbb")
    password = DevEnv::Secrets.new(@config.secret_dir).password_for(key)

    in_project do
      out, = capture_io { @cli.send(:cmd_creds, []) }
      assert_includes out, "feature  https://aaaaaaaa.proj.example.com  dev / #{password}"
      refute_includes out, "bbbbbbbb"
    end
  end

  def test_creds_does_not_create_a_password_for_a_public_environment
    key = save_state(project: "proj", branch: "feature", port: 4001, identifier: "aaaaaaaa", "basic_auth" => false)
    secrets = DevEnv::Secrets.new(@config.secret_dir)

    in_project do
      out, = capture_io { @cli.send(:cmd_creds, ["feature"]) }

      assert_includes out, "proj/feature is public"
      refute secrets.password?(key)
    end
  end
end
