# frozen_string_literal: true

require_relative "test_helper"

class CLITest < Minitest::Test
  include DevEnvTest

  # Records what cloning a seed template asks of the server.
  class FakeCloneDatabase
    attr_reader :clones

    def initialize
      @clones = []
      @databases = []
    end

    def exists?(name) = @databases.include?(name)
    def create(name) = @databases << name
    def drop(name, **) = @databases.delete(name)
    def url(name) = "mysql2://127.0.0.1:3306/#{name}"
    def resource_identity(name) = { "adapter" => "mysql", "host" => "127.0.0.1", "port" => 3306,
                                    "database" => name }
    def clone_from(template, name, **) = @clones << [template, name]
  end

  def setup
    @config = build_config
    @cli = DevEnv::CLI.new(config: @config)
    FileUtils.mkdir_p([@config.state_dir, @config.run_dir, @config.secret_dir])
    @store = DevEnv::Store.new(state_dir: @config.state_dir, run_dir: @config.run_dir,
                               secret_dir: @config.secret_dir)
  end

  # Runs the block inside a git repository configured as project `name`, so
  # CLI commands can load the project the way they do in real use.
  def in_project(name = "proj", settings = {})
    repo = Dir.mktmpdir.tap { |d| @tmp_dirs << d }
    system("git", "init", "-q", repo)
    File.write(File.join(repo, ".dev-env.json"), JSON.generate({ "name" => name }.merge(settings)))
    Dir.chdir(repo) { yield }
  end

  def save_state(project:, branch:, port:, id:, **extra)
    key = "#{project}--#{DevEnv::Util.slugify(branch)}--#{id}"
    @store.save(key, {
      "id" => id, "key" => key, "project" => project, "branch" => branch,
      "domain" => "#{id}-#{project}.example.com", "port" => port,
      "database" => "dev_env_#{project}_#{port}_#{id}", "databases" => ["dev_env_#{project}_#{port}_#{id}"],
      "worktree" => "/nowhere/#{key}",
      "project_root" => "/nowhere/#{project}",
      "worktree_owned" => false, "basic_auth" => true, "process_manager" => nil,
      "after_down" => [],
    }.merge(extra))
    @store.write_env(key, { "PORT" => port.to_s, "WORKTREE" => "/nowhere/#{key}" })
    key
  end

  def create_owned_worktree
    repo = Dir.mktmpdir.tap { |dir| @tmp_dirs << dir }
    container = Dir.mktmpdir.tap { |dir| @tmp_dirs << dir }
    worktree = File.join(container, "feature")
    system("git", "init", "-q", "-b", "main", repo)
    system("git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t",
           "commit", "-q", "--allow-empty", "-m", "init")
    system("git", "-C", repo, "worktree", "add", "-q", "-b", "feature", worktree)
    [repo, worktree]
  end

  # Replaces everything teardown asks of systemd and Caddy.
  def stub_teardown(status: "inactive")
    @cli.send(:teardown_caddy).define_singleton_method(:reload) { nil }
    @cli.send(:systemd).define_singleton_method(:systemctl) { |*| true }
    @cli.send(:systemd).define_singleton_method(:status) { |_| status }
    @cli.send(:systemd).define_singleton_method(:configure_process_manager) { |*| nil }
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

  def test_help_prints_usage_and_every_command_supports_help_without_running
    out, = capture_io { @cli.start(["help"]) }
    assert_includes out, "Usage: dev-env <command>"
    assert_includes out, "up [branch]"
    assert_includes out, "down --all"

    DevEnv::CLI::COMMANDS.each do |command|
      out, = capture_io do
        error = assert_raises(SystemExit) { @cli.start([command, "--help"]) }
        assert_equal 0, error.status
      end
      assert_includes out, "Usage: dev-env #{command}"
    end

    out, = capture_io { assert_raises(SystemExit) { @cli.start(["help", "down"]) } }
    assert_includes out, "Usage: dev-env down"
  end

  def test_errors_invalid_options_and_unknown_commands_exit_nonzero
    [["setup", "--bogus"], ["list", "extra"], ["up", "one", "two"]].each do |argv|
      command = argv.first
      _, err = capture_io do
        error = assert_raises(SystemExit) { @cli.start(argv) }
        assert_equal 1, error.status
      end
      assert_includes err, "Usage: dev-env #{command}"
      refute_includes err, "cli.rb:"
    end

    Dir.chdir(Dir.mktmpdir.tap { |d| @tmp_dirs << d }) do
      _, err = capture_io { assert_raises(SystemExit) { @cli.start(["init"]) } }
      assert_includes err, "not inside a git repository"
    end

    exit_error = assert_raises(SystemExit) { capture_io { @cli.start(["bogus"]) } }
    assert_equal 1, exit_error.status
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

  def test_lifecycle_locks_serialize_the_same_target_and_machine_wide_operations
    other = DevEnv::CLI.new(config: @config)
    different_acquired = false

    @cli.send(:with_environment_lifecycle_lock, "/repo", "proj", "feature-a") do
      other.send(:with_environment_lifecycle_lock, "/repo", "proj", "feature-b") { different_acquired = true }
      error = assert_raises(DevEnv::Error) do
        other.send(:with_environment_lifecycle_lock, "/repo", "proj", "feature-a") { flunk "lock was acquired" }
      end
      assert_includes error.message, "another dev-env operation is targeting proj/feature-a"
      assert_includes error.message, Process.pid.to_s

      error = assert_raises(DevEnv::Error) do
        other.send(:with_machine_lifecycle_lock) { flunk "lock was acquired" }
      end
      assert_includes error.message, "another dev-env lifecycle operation"
    end
    assert different_acquired

    @cli.send(:with_machine_lifecycle_lock) do
      error = assert_raises(DevEnv::Error) do
        other.send(:with_environment_lifecycle_lock, "/repo", "proj", "feature") { flunk "lock was acquired" }
      end
      assert_includes error.message, "machine-wide dev-env operation"
    end

    acquired = false
    other.send(:with_environment_lifecycle_lock, "/repo", "proj", "feature-a") { acquired = true }
    assert acquired, "the target lock should be released when the operation finishes"
  end

  def test_base_domain_change_is_automatic_when_empty_and_requires_down_all_for_environments
    File.write(File.join(@config.sites_dir, DevEnv::Caddy::WILDCARD_SITE), <<~CADDY)
      # Managed by dev-env
      https://*.other.net {
      }
    CADDY

    @cli.send(:prepare_base_domain_change!) # no environments: setup may overwrite it

    save_state(project: "proj", branch: "feature", port: 4001, id: "aaaaaaaa")
    error = assert_raises(DevEnv::Error) { @cli.send(:prepare_base_domain_change!) }
    assert_includes error.message, "dev-env down --all"
  end

  def test_setup_stops_when_writing_the_caddyfile_fails
    @cli.define_singleton_method(:capture) { |*| "127.0.0.1" }
    previous_path = ENV["PATH"]
    bin = Dir.mktmpdir.tap { |dir| @tmp_dirs << dir }
    File.write(File.join(bin, "sudo"), "#!/bin/sh\n/bin/cat >/dev/null\nexit 1\n")
    FileUtils.chmod(0o755, File.join(bin, "sudo"))
    ENV["PATH"] = bin

    error = nil
    capture_io { error = assert_raises(DevEnv::Error) { @cli.send(:cmd_setup, []) } }

    assert_includes error.message, "could not write #{@config.caddyfile}"
  ensure
    ENV["PATH"] = previous_path
  end

  def test_install_dependencies_restores_a_matching_cache_but_never_a_failed_install
    calls = File.join(Dir.mktmpdir.tap { |dir| @tmp_dirs << dir }, "calls")
    install = <<~SH.strip
      if [ -f node_modules/example/index.js ]; then echo seeded; else echo cold; fi >> #{Shellwords.escape(calls)}
      mkdir -p node_modules/example && echo installed > node_modules/example/index.js
    SH
    settings = {
      "commands" => { "install" => install },
      "install_cache" => { "directory" => "node_modules", "key_files" => ["package.json", "yarn.lock"] },
    }

    in_project("proj", settings) do
      File.write("package.json", "{\"private\":true}\n")
      File.write("yarn.lock", "# lock\n")

      first_out, = capture_io { @cli.send(:install_dependencies, install, Dir.pwd, {}) }
      FileUtils.rm_rf("node_modules")
      second_out, = capture_io { @cli.send(:install_dependencies, install, Dir.pwd, {}) }

      assert_equal %w[cold seeded], File.readlines(calls, chomp: true)
      assert_includes first_out, "Saving node_modules to the install cache"
      assert_includes second_out, "Restoring cached node_modules"
    end

    failing = "mkdir -p node_modules/example && exit 1"
    in_project("proj", settings.merge("commands" => { "install" => failing })) do
      File.write("package.json", "{\"private\":true}\n")
      File.write("yarn.lock", "# a different lock\n")

      capture_io do
        assert_raises(DevEnv::Error) { @cli.send(:install_dependencies, failing, Dir.pwd, {}) }
      end

      # Only the earlier successful install left a snapshot.
      assert_equal 1, Dir.glob(File.join(@config.cache_dir, "installs", "*", "fingerprint")).length
    end
  end

  def test_cloning_a_template_builds_it_once_and_preserves_configured_url_options
    calls = File.join(Dir.mktmpdir.tap { |dir| @tmp_dirs << dir }, "calls")
    settings = {
      "seed_template" => { "build" => "echo built ${DATABASE} $DATABASE_URL >> #{Shellwords.escape(calls)}" },
      "env" => { "DATABASE_URL" => "${DATABASE_URL}?ssl-mode=REQUIRED" },
    }

    in_project("proj", settings) do
      db = FakeCloneDatabase.new
      template = @cli.send(:project).seed_template

      2.times do
        capture_io { @cli.send(:clone_template, template, db, "dev_env_proj_4000_ab", Dir.pwd, {}) }
      end

      # Rebuilding the project environment from template variables preserves
      # its configured URL options while changing the database name.
      assert_equal ["built dev_env_proj_template mysql2://127.0.0.1:3306/dev_env_proj_template?ssl-mode=REQUIRED"],
                   File.readlines(calls, chomp: true)
      assert_equal [["dev_env_proj_template", "dev_env_proj_4000_ab"]] * 2, db.clones
    end
  end

  def test_list_shows_a_row_per_environment_and_ls_is_an_alias
    out, = capture_io { @cli.start(["list"]) }
    assert_includes out, "No environments."

    5.times { |n| save_state(project: "proj", branch: "branch-#{n}", port: 4000 + n, id: "id#{n}aaaaa") }
    @cli.send(:systemd).define_singleton_method(:status) { |_| "inactive" }

    out, = capture_io { @cli.start(["list"]) }
    lines = out.lines.map(&:chomp).reject(&:empty?)
    assert_equal %w[ID PROJECT BRANCH PORT STATUS URL], lines.first.split
    assert_equal 6, lines.length
    assert_includes out, "https://id0aaaaa-proj.example.com"

    ls_out, = capture_io { @cli.start(["ls"]) }
    assert_equal out, ls_out
  end

  def test_logs_accepts_a_target_and_follow_option
    save_state(project: "proj", branch: "feature", port: 4000, id: "aaaaaaaa")
    executed = nil
    @cli.define_singleton_method(:exec) { |*args| executed = args }

    @cli.send(:cmd_logs, ["aaaaaaaa", "--follow"])

    assert_equal ["journalctl", "--user", "-u", "dev-env@proj--feature--aaaaaaaa.service", "--follow"], executed
  end

  def test_resolve_finds_state_by_exact_project_and_branch_despite_colliding_slugs
    slashed = save_state(project: "proj", branch: "feature/foo", port: 4001, id: "aaaaaaaa")
    dashed  = save_state(project: "proj", branch: "feature-foo", port: 4002, id: "bbbbbbbb")
    other   = save_state(project: "zed", branch: "feature/zed", port: 4003, id: "cccccccc")

    in_project do
      assert_equal slashed, @cli.send(:resolve, "feature/foo")
      assert_equal dashed, @cli.send(:resolve, "feature-foo")
      assert_equal other, @cli.send(:resolve, "cccccccc"), "an environment ID is accepted as-is"
      error = assert_raises(DevEnv::Error) { @cli.send(:resolve, "feature/zed") }
      assert_includes error.message, "no environment"
    end
  end

  def test_up_rejects_a_second_environment_for_the_branch_and_infers_it_from_the_checkout
    save_state(project: "proj", branch: "feature", port: 4001, id: "aaaaaaaa")
    in_project do
      error = assert_raises(DevEnv::Error) { @cli.send(:cmd_up, ["feature"]) }
      assert_includes error.message, "already has an environment"

      system("git", "checkout", "-q", "-b", "feature")
      error = assert_raises(DevEnv::Error) { @cli.send(:cmd_up, []) }
      assert_includes error.message, "already has an environment", "expected the checked-out branch to be inferred"
    end
  end

  def test_up_uses_the_current_branch_as_the_default_base_for_a_new_branch
    base = nil
    cli = DevEnv::CLI.new(config: @config)
    in_project do
      system("git", "add", ".dev-env.json")
      system("git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "initial")
      system("git", "checkout", "-qb", "parent")

      cli.send(:systemd).define_singleton_method(:installed?) { true }
      cli.send(:worktrees).define_singleton_method(:create) { |_, _, ref| base = ref }
      database = Object.new
      database.define_singleton_method(:exists?) { |_| false }
      database.define_singleton_method(:create) { |_| true }
      cli.define_singleton_method(:database_for) { |_| database }
      cli.define_singleton_method(:build_environment) { |*| nil }
      cli.define_singleton_method(:print_summary) { |_, total:| total }

      capture_io { cli.send(:cmd_up, ["child", "--no-seed"]) }
    end

    assert_equal "parent", base
  end

  def test_up_uses_the_project_public_default_and_options_override_it
    private_state = up_state_for({})
    assert_match(/\A[a-z0-9]{8}\z/, private_state["id"])
    assert_equal "proj--feature--#{private_state['id']}", private_state["key"]
    assert_equal "#{private_state['id']}-proj.example.com", private_state["domain"]
    assert_equal "dev_env_proj_#{private_state['port']}_#{private_state['id']}", private_state["database"]
    assert_equal true, private_state["basic_auth"]
    assert_equal false, up_state_for({ "public" => true })["basic_auth"]

    assert_equal false, up_state_for({ "public" => false }, "--public")["basic_auth"]
    assert_equal true, up_state_for({ "public" => true }, "--private")["basic_auth"]
  end

  def test_generated_ids_retry_recorded_and_in_flight_collisions
    save_state(project: "proj", branch: "feature", port: 4001, id: "aaaaaaaa")
    sequence = %w[aaaaaaaa bbbbbbbb]
    @cli.define_singleton_method(:random_environment_id) { sequence.shift }

    selected = @cli.send(:with_environment_id_reservation) { |id| id }
    assert_equal "bbbbbbbb", selected
    assert_empty sequence

    holder = DevEnv::CLI.new(config: @config)
    other = DevEnv::CLI.new(config: @config)
    holder.define_singleton_method(:random_environment_id) { "cccccccc" }
    sequence = %w[cccccccc dddddddd]
    other.define_singleton_method(:random_environment_id) { sequence.shift }

    holder.send(:with_environment_id_reservation) do |first|
      second = other.send(:with_environment_id_reservation) { |id| id }
      assert_equal "cccccccc", first
      assert_equal "dddddddd", second
    end
    assert_empty sequence
  end

  def test_up_summary_prints_command_rows_and_the_total_and_warns_for_a_silent_command
    worktree = Dir.mktmpdir.tap { |dir| @tmp_dirs << dir }
    key = save_state(project: "proj", branch: "feature", port: 4001, id: "aaaaaaaa",
                     "worktree" => worktree)

    in_project("proj", "summary" => { "Login" => "echo https://${DOMAIN}/admin?lt=$(basename $(pwd))" }) do
      out, = capture_io { @cli.send(:print_summary, key, total: 65) }

      assert_includes out, "ID         aaaaaaaa"
      assert_includes out, "dev-env down aaaaaaaa"
      assert_includes out, "Login      https://aaaaaaaa-proj.example.com/admin?lt=#{File.basename(worktree)}"
      assert out.rstrip.end_with?("Total      [1m 05s]"), out
    end

    # A fresh CLI, because the project and its summary are memoized per process.
    in_project("proj", "summary" => { "Login" => "exit 3" }) do
      out, err = capture_io { DevEnv::CLI.new(config: @config).send(:print_summary, key, total: 1) }

      refute_includes out, "Login"
      assert_includes err, "Login"
      assert out.rstrip.end_with?("Total      [1s]"), out
    end
  end

  def test_failed_up_stops_the_service_and_reloads_caddy_before_rolling_back
    cli = DevEnv::CLI.new(config: @config)
    events = []
    route = nil

    in_project do
      system("git", "add", ".dev-env.json")
      system("git", "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "initial")
      system("git", "checkout", "-qb", "feature")

      cli.send(:systemd).define_singleton_method(:installed?) { true }
      cli.send(:systemd).define_singleton_method(:configure_process_manager) { |*| nil }
      cli.send(:systemd).define_singleton_method(:systemctl) { |*| events << :stop; true }
      cli.send(:systemd).define_singleton_method(:status) { |_| "inactive" }
      cli.send(:caddy).define_singleton_method(:reload) { events << :reload }
      database = Object.new
      database.define_singleton_method(:exists?) { |_| false }
      database.define_singleton_method(:create) { |_| true }
      database.define_singleton_method(:drop) do |*, **|
        events << :drop
        raise DevEnv::Error, "drop failed"
      end
      cli.define_singleton_method(:database_for) { |_| database }
      cli.define_singleton_method(:build_environment) do |state, *|
        route = cli.send(:caddy).site_path(state["key"])
        FileUtils.mkdir_p(File.dirname(route))
        File.write(route, "# route\n")
        raise DevEnv::Error, "start failed"
      end

      capture_io do
        assert_raises(DevEnv::Error) { cli.send(:cmd_up, ["feature", "--worktree", Dir.pwd, "--no-seed"]) }
      end
    end

    assert_equal %i[stop reload drop], events
    refute_path_exists route
    assert_equal 1, @store.keys.length, "incomplete rollback should retain environment state"
  end

  def test_down_removes_state_caddy_route_and_password
    key = save_state(project: "proj", branch: "feature", port: 4001, id: "aaaaaaaa")
    @store.password_for(key)

    in_project do
      route = @cli.send(:caddy).site_path(key)
      FileUtils.mkdir_p(File.dirname(route))
      File.write(route, "# Managed by dev-env\n")
      stub_teardown
      dropped = stub_database_drops

      out, = capture_io { @cli.send(:cmd_down, ["aaaaaaaa"]) }

      refute @store.exist?(key)
      refute_path_exists route
      refute @store.password?(key)
      assert_equal ["dev_env_proj_4001_aaaaaaaa"], dropped
      assert_includes out, "proj/feature removed"
    end
  end

  def test_down_keeps_resources_and_state_when_the_service_does_not_stop
    key = save_state(project: "proj", branch: "feature", port: 4001, id: "aaaaaaaa")
    stub_teardown(status: "active")
    dropped = stub_database_drops

    error = nil
    capture_io { error = assert_raises(DevEnv::Error) { @cli.send(:cmd_down, ["aaaaaaaa"]) } }

    assert_includes error.message, "did not stop"
    assert_empty dropped
    assert @store.exist?(key)
  end

  def test_down_continues_cleanup_and_keeps_retriable_state_after_a_drop_failure
    root, worktree = create_owned_worktree
    databases = %w[primary extra]
    key = save_state(project: "proj", branch: "feature", port: 4001, id: "aaaaaaaa",
                     "databases" => databases, "worktree" => worktree,
                     "project_root" => root, "worktree_owned" => true)
    stub_teardown
    calls = []
    fail_once = true
    database = Object.new
    database.define_singleton_method(:drop) do |name, **|
      calls << name
      if name == "primary" && fail_once
        fail_once = false
        raise DevEnv::Error, "database unavailable"
      end
    end
    @cli.define_singleton_method(:database_for) { |_| database }

    error = nil
    capture_io { error = assert_raises(DevEnv::Error) { @cli.send(:cmd_down, ["aaaaaaaa"]) } }

    assert_includes error.message, "drop database primary"
    assert_equal databases, calls
    assert @store.exist?(key)
    refute_path_exists worktree, "worktree cleanup should continue after the database failure"

    capture_io { @cli.send(:cmd_down, ["aaaaaaaa"]) }
    assert_equal databases * 2, calls
    refute @store.exist?(key)
  end

  def test_down_requires_force_before_discarding_changes_in_an_owned_worktree
    root, worktree = create_owned_worktree
    File.write(File.join(worktree, "uncommitted.txt"), "discard me")
    key = save_state(project: "proj", branch: "feature", port: 4001, id: "aaaaaaaa",
                     "worktree" => worktree, "project_root" => root, "worktree_owned" => true)

    error = assert_raises(DevEnv::Error) { @cli.send(:cmd_down, ["aaaaaaaa"]) }
    assert_includes error.message, "has uncommitted changes"
    assert_includes error.message, "--force"
    assert_includes error.message, "--keep-worktree"
    assert @store.exist?(key)
    assert_path_exists worktree

    stub_teardown
    stub_database_drops
    capture_io { @cli.send(:cmd_down, ["aaaaaaaa", "--force"]) }
    refute @store.exist?(key)
    refute_path_exists worktree
  end

  def test_down_takes_an_id_explicitly_or_inferred_from_the_current_worktree_but_never_a_branch
    worktree = Dir.mktmpdir.tap { |d| @tmp_dirs << d }
    key = save_state(project: "proj", branch: "feature", port: 4001, id: "aaaaaaaa",
                     "worktree" => worktree)

    in_project do
      error = assert_raises(DevEnv::Error) { @cli.send(:cmd_down, ["feature"]) }
      assert_includes error.message, "no environment \"feature\""

      error = assert_raises(DevEnv::Error) { @cli.send(:cmd_down, []) }
      assert_includes error.message, "Usage: dev-env down [id]"
      assert @store.exist?(key)

      stub_teardown
      stub_database_drops
      out, = capture_io { Dir.chdir(worktree) { @cli.send(:cmd_down, []) } }
      refute @store.exist?(key), "expected the environment to be inferred from the worktree"
      assert_includes out, "proj/feature removed"
    end
  end

  def test_down_all_removes_every_projects_active_or_inactive_environment_outside_a_repository
    first = save_state(project: "proj", branch: "feature", port: 4001, id: "aaaaaaaa")
    second = save_state(project: "zed", branch: "main", port: 4002, id: "bbbbbbbb")
    File.write(File.join(@config.sites_dir, DevEnv::Caddy::WILDCARD_SITE), <<~CADDY)
      # Managed by dev-env
      https://*.other.net {
      }
    CADDY

    units = []
    @cli.send(:systemd).define_singleton_method(:systemctl) { |*args| units << args; true }
    @cli.send(:systemd).define_singleton_method(:status) { |_| "inactive" }
    @cli.send(:systemd).define_singleton_method(:configure_process_manager) { |*| nil }
    @cli.send(:teardown_caddy).define_singleton_method(:reload) { nil }
    dropped = stub_database_drops
    elsewhere = Dir.mktmpdir.tap { |dir| @tmp_dirs << dir }

    out, = capture_io { Dir.chdir(elsewhere) { @cli.start(["down", "--all"]) } }

    assert_empty @store.keys
    assert_equal ["dev_env_proj_4001_aaaaaaaa", "dev_env_zed_4002_bbbbbbbb"], dropped.sort
    assert_equal [first, second].sort,
                 units.filter_map { |args| args.grep(String).filter_map { _1[/\Adev-env@(.+)\.service\z/, 1] }.first }.sort
    assert_includes out, "proj/feature removed"
    assert_includes out, "zed/main removed"
    assert_includes out, "All environments removed"
  end

  def test_down_drops_every_recorded_database_with_the_recorded_adapter
    key = save_state(project: "proj", branch: "feature", port: 4001, id: "aaaaaaaa",
                     "databases" => ["dev_env_proj_4001_aaaaaaaa", "dev_env_proj_4001_aaaaaaaa_data_science"],
                     "database_settings" => { "adapter" => "mysql", "user" => "sample_dev" })

    in_project do
      stub_teardown

      state = @store.load(key)
      db = @cli.send(:database_for, state)
      assert_equal "mysql2://sample_dev@127.0.0.1:3306/x", db.url("x"), "the adapter comes from state, not the repository"

      dropped = stub_database_drops
      capture_io { @cli.send(:cmd_down, ["aaaaaaaa"]) }
      assert_equal ["dev_env_proj_4001_aaaaaaaa", "dev_env_proj_4001_aaaaaaaa_data_science"], dropped
    end
  end

  def test_down_runs_after_down_hooks_with_vars_and_keep_flags_and_survives_failures
    key = save_state(project: "proj", branch: "feature", port: 4001, id: "aaaaaaaa",
                     "after_down" => ["cleanup 4001 feature", "exit 1"])

    in_project("proj", "after_down" => ["cleanup ${PORT} ${BRANCH}", "exit 1"]) do
      stub_teardown
      stub_database_drops
      calls = []
      @cli.define_singleton_method(:run) do |*cmd, **kwargs|
        calls << [cmd.join(" "), kwargs]
        !cmd.join(" ").start_with?("exit") # the second hook fails
      end

      out, err = capture_io { @cli.send(:cmd_down, ["aaaaaaaa", "--keep-worktree"]) }

      hook, kwargs = calls.find { |command,| command == "cleanup 4001 feature" }
      assert hook, "expected the interpolated hook to run, got: #{calls.map(&:first)}"
      assert_equal "true", kwargs[:env]["DEV_ENV_KEEP_WORKTREE"]
      assert_equal "false", kwargs[:env]["DEV_ENV_KEEP_DATABASE"]
      assert_includes err.to_s + out, "after_down command failed"
      refute @store.exist?(key), "a failing hook must not abort down"
    end
  end

  def test_warm_rewrites_only_recorded_environments_of_the_current_project
    mine  = save_state(project: "proj", branch: "feature", port: 4001, id: "aaaaaaaa", "basic_auth" => false)
    other = save_state(project: "zed", branch: "other", port: 4002, id: "bbbbbbbb", "basic_auth" => false)

    in_project do
      @cli.send(:caddy).define_singleton_method(:reload) { nil }
      @cli.define_singleton_method(:capture) { |*| "200" } # curl always succeeds

      out, = capture_io { @cli.send(:cmd_warm, []) }

      assert_path_exists File.join(@config.sites_dir, DevEnv::Caddy::WILDCARD_SITE)
      assert_path_exists File.join(@config.sites_dir, DevEnv::Caddy::ROUTES_DIR, "#{mine}.caddy")
      assert_empty Dir.glob(File.join(@config.sites_dir, "**", "#{other}.caddy"))
      assert_includes out, "Certificates warmed for proj"
    end
  end

  def test_creds_enumerates_the_projects_environments_and_never_invents_a_password
    key = save_state(project: "proj", branch: "feature", port: 4001, id: "aaaaaaaa")
    public_key = save_state(project: "proj", branch: "open", port: 4002, id: "bbbbbbbb", "basic_auth" => false)
    save_state(project: "zed", branch: "other", port: 4003, id: "cccccccc")
    password = @store.password_for(key)

    in_project do
      out, = capture_io { @cli.send(:cmd_creds, []) }
      assert_includes out, "feature  https://aaaaaaaa-proj.example.com  dev / #{password}"
      refute_includes out, "cccccccc"

      out, = capture_io { @cli.send(:cmd_creds, ["open"]) }
      assert_includes out, "proj/open is public"
      refute @store.password?(public_key)
    end
  end
end
