# frozen_string_literal: true

require_relative "test_helper"

class ProjectTest < Minitest::Test
  include DevEnvTest

  def setup
    @config = build_config
  end

  def test_derived_names_pool_and_paths
    project = build_project(@config, {}, root: "/repos/My App")
    assert_equal "my-app", project.name
    assert_equal %w[dev1 dev2], project.pool
    assert_equal "my-app-dev1", project.key_for("dev1")
    assert_equal "dev1.my-app.example.com", project.domain_for("dev1")
    assert_equal "dev_env_my_app_dev1", project.database_for("my-app-dev1")
    assert_equal "/repos/My App-worktrees", project.worktree_root
    assert_equal File.join(@config.dump_dir, "my-app-seed.pdump"), project.default_dump
  end

  def test_process_manager
    assert_nil build_project(@config).process_manager
    assert_equal "overmind", build_project(@config, { "process_manager" => "overmind" }).process_manager
    assert_equal "foreman", build_project(@config, { "process_manager" => "foreman" }).process_manager
  end

  def test_subdomains_defaults_shorthand_and_validation
    assert_equal [{ "label" => "", "auth" => true }, { "label" => "app", "auth" => true }],
                 build_project(@config).subdomains
    project = build_project(@config, { "subdomains" => { "" => true, "mcp" => false, "api" => {} } })
    assert_equal [true, false, true], project.subdomains.map { _1["auth"] }
    assert_raises(DevEnv::Error) { build_project(@config, { "subdomains" => {} }).subdomains }
    assert_raises(DevEnv::Error) { build_project(@config, { "subdomains" => { "a.b" => true } }).subdomains }
  end

  def test_host_folding_depends_on_certificate_mode
    exact = build_project(@config)
    assert_equal "dev1.p.example.com", exact.host_for("dev1.p.example.com", "")
    assert_equal "app.dev1.p.example.com", exact.host_for("dev1.p.example.com", "app")

    wildcard = build_project(build_config("acme_dns_provider" => "route53"))
    assert_equal "app-dev1.p.example.com", wildcard.host_for("dev1.p.example.com", "app")
  end

  def test_vars_and_app_env
    project = build_project(@config, { "name" => "proj", "env" => { "HOST" => "${APP_DOMAIN}" } })
    state = { "domain" => "dev1.proj.example.com", "port" => 4001, "database" => "db",
              "slot" => "dev1", "project" => "proj", "worktree" => "/wt" }
    vars = project.vars_for(state)
    assert_equal "app.dev1.proj.example.com", vars["APP_DOMAIN"]
    assert_equal "app\\.dev1\\.proj\\.example\\.com", vars["APP_DOMAIN_RE"]
    assert_equal "3", vars["TLD_LENGTH"]
    assert_equal "postgresql:///db", vars["DATABASE_URL"]

    env = project.app_env_for(vars)
    assert_equal "app.dev1.proj.example.com", env["HOST"]
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
