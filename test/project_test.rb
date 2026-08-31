# frozen_string_literal: true

require_relative "test_helper"

class ProjectTest < Minitest::Test
  include DevEnvTest

  def setup
    @config = build_config
  end

  def test_derived_names_and_paths
    project = build_project(@config, {}, root: "/repos/My App")
    assert_equal "my-app", project.name
    assert_equal "my-app--dev-env-support--pkliinp6", project.key_for("dev-env-support", "pkliinp6")
    assert_equal "pkliinp6-my-app.example.com", project.domain_for("pkliinp6")
    assert_equal "dev_env_my_app_4593_pkliinp6", project.database_for(4593, "pkliinp6")
    assert_equal "/repos/My App-worktrees", project.worktree_root
    assert_equal File.join(@config.dump_dir, "my-app-seed.pdump"), project.default_dump
  end

  def test_artifact_keys_keep_colliding_branch_slugs_distinct_through_the_environment_id
    project = build_project(@config, { "name" => "proj" })
    assert_equal "proj--feature-foo--aaaaaaaa", project.key_for("feature/foo", "aaaaaaaa")
    assert_equal "proj--feature-foo--bbbbbbbb", project.key_for("feature-foo", "bbbbbbbb")
  end

  def test_longest_database_name_fits_postgres_limit
    project = build_project(@config, { "name" => "a" * DevEnv::Util::MAX_LABEL })
    database = project.database_for(65_535, "abcdefgh")
    assert_operator database.bytesize, :<=, 63
    assert_equal "dev_env_#{'a' * 40}_65535_abcdefgh", database
  end

  def test_database_adapter_shapes_dump_name_and_database_url
    project = build_project(@config, { "name" => "proj", "database" => { "adapter" => "mysql", "user" => "sample_dev" } })
    assert_equal File.join(@config.dump_dir, "proj-seed.sql"), project.default_dump

    state = { "domain" => "pkliinp6-proj.example.com", "port" => 4001, "database" => "db",
              "branch" => "x", "project" => "proj", "worktree" => "/wt" }
    assert_equal "mysql2://sample_dev@127.0.0.1:3306/db", project.vars_for(state)["DATABASE_URL"]
  end

  def test_process_manager
    assert_nil build_project(@config).process_manager
    assert_equal "overmind", build_project(@config, { "process_manager" => "overmind" }).process_manager
    assert_equal "foreman", build_project(@config, { "process_manager" => "foreman" }).process_manager
  end

  def test_after_down_defaults_empty_and_wraps_arrays
    assert_equal [], build_project(@config).after_down
    assert_equal ["bin/cleanup"], build_project(@config, { "after_down" => ["bin/cleanup"] }).after_down
  end

  def test_summary_defaults_empty_and_requires_an_object
    assert_equal({}, build_project(@config).summary)
    assert_equal({ "Login" => "bin/token" }, build_project(@config, { "summary" => { "Login" => "bin/token" } }).summary)

    error = assert_raises(DevEnv::Error) { build_project(@config, { "summary" => ["bin/token"] }).summary }
    assert_includes error.message, "must be an object"
  end

  def test_public_defaults_false_and_requires_a_boolean
    refute build_project(@config).public?
    assert build_project(@config, { "public" => true }).public?
    refute build_project(@config, { "public" => false }).public?

    error = assert_raises(DevEnv::Error) { build_project(@config, { "public" => "yes" }).public? }
    assert_includes error.message, "must be true or false"
  end

  def test_subdomains_defaults_shorthand_and_validation
    assert_equal [{ "label" => "", "auth" => true }, { "label" => "app", "auth" => true }],
                 build_project(@config).subdomains
    project = build_project(@config, { "subdomains" => { "" => true, "mcp" => false, "api" => {} } })
    assert_equal [true, false, true], project.subdomains.map { _1["auth"] }
    assert_raises(DevEnv::Error) { build_project(@config, { "subdomains" => {} }).subdomains }
    assert_raises(DevEnv::Error) { build_project(@config, { "subdomains" => { "a.b" => true } }).subdomains }
  end

  def test_subdomain_labels_fold_into_the_wildcard_covered_leftmost_label
    project = build_project(@config)
    assert_equal "pkliinp6-p.example.com", project.host_for("pkliinp6-p.example.com", "")
    assert_equal "app-pkliinp6-p.example.com", project.host_for("pkliinp6-p.example.com", "app")
  end

  def test_vars_and_app_env
    project = build_project(@config, { "name" => "proj", "env" => { "HOST" => "${APP_DOMAIN}" } })
    state = { "domain" => "pkliinp6-proj.example.com", "port" => 4001, "database" => "db",
              "branch" => "feature/x", "project" => "proj", "worktree" => "/wt" }
    vars = project.vars_for(state)
    assert_equal "app-pkliinp6-proj.example.com", vars["APP_DOMAIN"]
    assert_equal "app\\-pkliinp6\\-proj\\.example\\.com", vars["APP_DOMAIN_RE"]
    assert_equal "2", vars["TLD_LENGTH"]
    assert_equal "feature/x", vars["BRANCH"]
    refute vars.key?("SLOT")
    assert_equal "postgresql:///db", vars["DATABASE_URL"]

    env = project.app_env_for(vars)
    assert_equal "app-pkliinp6-proj.example.com", env["HOST"]
    assert_equal "4001", env["PORT"]
    assert_equal "/wt", env["WORKTREE"]
    assert_includes env["PATH"], "/usr/bin"
  end

  def test_load_discovers_repo_and_prefers_local_settings_over_global_settings
    repo = Dir.mktmpdir.tap { |d| @tmp_dirs << d }
    system("git", "init", "-q", repo)
    config = build_config("projects" => { repo => { "name" => "global-thing" } })
    Dir.chdir(repo) do
      global_project = DevEnv::Project.load(config)
      assert_equal "global-thing", global_project.name

      File.write(File.join(repo, ".dev-env.json"), JSON.generate("name" => "thing"))
      project = DevEnv::Project.load(config)
      assert_equal "thing", project.name
      assert_equal File.realpath(repo), File.realpath(project.root)
    end
  end

  def test_global_settings_apply_inside_a_worktree
    repo = Dir.mktmpdir.tap { |dir| @tmp_dirs << dir }
    worktree = Dir.mktmpdir.tap { |dir| @tmp_dirs << dir }
    system("git", "init", "-q", repo)
    File.write(File.join(repo, "README"), "test\n")
    system("git", "-C", repo, "add", "README")
    system("git", "-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.com",
           "commit", "-qm", "initial")
    FileUtils.remove_entry(worktree)
    system("git", "-C", repo, "worktree", "add", "-q", "-b", "feature", worktree)
    config = build_config("projects" => { repo => { "name" => "global-thing" } })

    Dir.chdir(worktree) do
      project = DevEnv::Project.load(config)
      assert_equal "global-thing", project.name
      assert_equal File.realpath(repo), File.realpath(project.root)
    end
  end

  def test_load_explains_both_project_configuration_options_when_neither_exists
    repo = Dir.mktmpdir.tap { |d| @tmp_dirs << d }
    system("git", "init", "-q", repo)

    Dir.chdir(repo) do
      error = assert_raises(DevEnv::Error) { DevEnv::Project.load(@config) }
      assert_includes error.message, "dev-env init"
      assert_includes error.message, "projects"
      assert_includes error.message, @config.path
    end
  end
end
