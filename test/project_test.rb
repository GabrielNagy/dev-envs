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
    assert_equal "my-app--dev-env-support--4593", project.key_for("dev-env-support", 4593)
    assert_equal "pkliinp6.my-app.example.com", project.domain_for("pkliinp6")
    assert_equal "dev_env_my_app_4593_pkliinp6", project.database_for(4593, "pkliinp6")
    assert_equal "/repos/My App-worktrees", project.worktree_root
    assert_equal File.join(@config.dump_dir, "my-app-seed.pdump"), project.default_dump
  end

  def test_colliding_branch_slugs_stay_distinct_through_the_port
    project = build_project(@config, { "name" => "proj" })
    assert_equal "proj--feature-foo--4001", project.key_for("feature/foo", 4001)
    assert_equal "proj--feature-foo--4002", project.key_for("feature-foo", 4002)
    refute_equal project.key_for("feature/foo", 4001), project.key_for("feature-foo", 4002)
  end

  def test_longest_database_name_fits_postgres_limit
    project = build_project(@config, { "name" => "a" * DevEnv::Util::MAX_LABEL })
    database = project.database_for(65_535, "abcd-efg")
    assert_operator database.bytesize, :<=, 63
    assert_equal "dev_env_#{'a' * 40}_65535_abcd_efg", database
  end

  def test_database_adapter_shapes_dump_name_and_database_url
    project = build_project(@config, { "name" => "proj", "database" => { "adapter" => "mysql", "user" => "sample_dev" } })
    assert_equal File.join(@config.dump_dir, "proj-seed.sql"), project.default_dump

    state = { "domain" => "pkliinp6.proj.example.com", "port" => 4001, "database" => "db",
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
    assert_equal "pkliinp6.p.example.com", project.host_for("pkliinp6.p.example.com", "")
    assert_equal "app-pkliinp6.p.example.com", project.host_for("pkliinp6.p.example.com", "app")
  end

  def test_vars_and_app_env
    project = build_project(@config, { "name" => "proj", "env" => { "HOST" => "${APP_DOMAIN}" } })
    state = { "domain" => "pkliinp6.proj.example.com", "port" => 4001, "database" => "db",
              "branch" => "feature/x", "project" => "proj", "worktree" => "/wt" }
    vars = project.vars_for(state)
    assert_equal "app-pkliinp6.proj.example.com", vars["APP_DOMAIN"]
    assert_equal "app\\-pkliinp6\\.proj\\.example\\.com", vars["APP_DOMAIN_RE"]
    assert_equal "3", vars["TLD_LENGTH"]
    assert_equal "feature/x", vars["BRANCH"]
    refute vars.key?("SLOT")
    assert_equal "postgresql:///db", vars["DATABASE_URL"]

    env = project.app_env_for(vars)
    assert_equal "app-pkliinp6.proj.example.com", env["HOST"]
    assert_equal "4001", env["PORT"]
    assert_equal "/wt", env["WORKTREE"]
    assert_includes env["PATH"], "/usr/bin"
  end

  def test_load_discovers_repo_and_prefers_local_settings
    repo = Dir.mktmpdir.tap { |d| @tmp_dirs << d }
    system("git", "init", "-q", repo)
    Dir.chdir(repo) do
      assert_raises(DevEnv::Error) { DevEnv::Project.load(@config) }
      File.write(File.join(repo, ".dev-env.json"), JSON.generate("name" => "thing"))
      project = DevEnv::Project.load(@config)
      assert_equal "thing", project.name
      assert_equal File.realpath(repo), File.realpath(project.root)
    end
  end
end
