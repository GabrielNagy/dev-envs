# frozen_string_literal: true

require_relative "test_helper"

class ProjectTest < Minitest::Test
  include DevEnvTest

  def setup
    @config = build_config
  end

  def test_derived_names_keys_domains_and_database_name_limit
    project = build_project(@config, {}, root: "/repos/My App")
    assert_equal "my-app", project.name
    assert_equal "my-app--dev-env-support--pkliinp6", project.key_for("dev-env-support", "pkliinp6")
    assert_equal "pkliinp6-my-app.example.com", project.domain_for("pkliinp6")
    assert_equal "dev_env_my_app_4593_pkliinp6", project.database_for(4593, "pkliinp6")
    assert_equal "/repos/My App-worktrees", project.worktree_root

    # Branch slugs may collide; the environment ID keeps the keys distinct.
    collides = build_project(@config, { "name" => "proj" })
    assert_equal "proj--feature-foo--aaaaaaaa", collides.key_for("feature/foo", "aaaaaaaa")
    assert_equal "proj--feature-foo--bbbbbbbb", collides.key_for("feature-foo", "bbbbbbbb")

    longest = build_project(@config, { "name" => "a" * DevEnv::Util::MAX_LABEL })
    database = longest.database_for(65_535, "abcdefgh")
    assert_operator database.bytesize, :<=, 63, "must fit PostgreSQL's identifier limit"
    assert_equal "dev_env_#{'a' * 40}_65535_abcdefgh", database
  end

  def test_settings_passthroughs_and_validation
    project = build_project(@config)
    assert_nil project.process_manager
    assert_equal [], project.after_down
    assert_equal({}, project.summary)
    refute project.public?

    configured = build_project(@config, { "process_manager" => "overmind", "after_down" => ["bin/cleanup"],
                                          "summary" => { "Login" => "bin/token" }, "public" => true })
    assert_equal "overmind", configured.process_manager
    assert_equal ["bin/cleanup"], configured.after_down
    assert_equal({ "Login" => "bin/token" }, configured.summary)
    assert configured.public?

    error = assert_raises(DevEnv::Error) { build_project(@config, { "summary" => ["bin/token"] }).summary }
    assert_includes error.message, "must be an object"
    error = assert_raises(DevEnv::Error) { build_project(@config, { "public" => "yes" }).public? }
    assert_includes error.message, "must be true or false"
  end

  def test_subdomains_defaults_shorthand_validation_and_host_folding
    project = build_project(@config)
    assert_equal [{ "label" => "", "auth" => true }, { "label" => "app", "auth" => true }],
                 project.subdomains
    shorthand = build_project(@config, { "subdomains" => { "" => true, "mcp" => false, "api" => {} } })
    assert_equal [true, false, true], shorthand.subdomains.map { _1["auth"] }
    assert_raises(DevEnv::Error) { build_project(@config, { "subdomains" => {} }).subdomains }
    assert_raises(DevEnv::Error) { build_project(@config, { "subdomains" => { "a.b" => true } }).subdomains }

    assert_equal "pkliinp6-p.example.com", project.host_for("pkliinp6-p.example.com", "")
    assert_equal "app-pkliinp6-p.example.com", project.host_for("pkliinp6-p.example.com", "app")
  end

  def test_vars_and_app_env
    project = build_project(@config, { "name" => "proj",
                                       "env" => { "HOST" => "${APP_DOMAIN}", "DATABASE_URL" => nil } })
    state = { "domain" => "pkliinp6-proj.example.com", "port" => 4001, "database" => "db",
              "branch" => "feature/x", "project" => "proj", "worktree" => "/wt" }
    vars = project.vars_for(state)
    assert_equal "app-pkliinp6-proj.example.com", vars["APP_DOMAIN"]
    assert_equal "app\\-pkliinp6\\-proj\\.example\\.com", vars["APP_DOMAIN_RE"]
    assert_equal "2", vars["TLD_LENGTH"]
    assert_equal "feature/x", vars["BRANCH"]
    assert_equal "postgresql:///db", vars["DATABASE_URL"]

    env = project.app_env_for(vars)
    assert_equal "app-pkliinp6-proj.example.com", env["HOST"]
    assert_equal "4001", env["PORT"]
    assert_equal "/wt", env["WORKTREE"]
    assert_includes env["PATH"], "/usr/bin"
    refute env.key?("DATABASE_URL"), "a null in project env withholds the default"

    mysql = build_project(@config, { "name" => "proj",
                                     "database" => { "adapter" => "mysql", "user" => "sample_dev" } })
    assert_equal "mysql2://sample_dev@127.0.0.1:3306/db", mysql.vars_for(state)["DATABASE_URL"]
  end

  def test_load_requires_configuration_and_prefers_local_settings_over_global_settings
    repo = Dir.mktmpdir.tap { |d| @tmp_dirs << d }
    system("git", "init", "-q", repo)

    Dir.chdir(repo) do
      error = assert_raises(DevEnv::Error) { DevEnv::Project.load(@config) }
      assert_includes error.message, "dev-env init"
      assert_includes error.message, @config.path

      config = build_config("projects" => { repo => { "name" => "global-thing" } })
      assert_equal "global-thing", DevEnv::Project.load(config).name

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
    system("git", "-C", repo, "-c", "user.name=Test", "-c", "user.email=test@example.com",
           "commit", "-q", "--allow-empty", "-m", "initial")
    FileUtils.remove_entry(worktree)
    system("git", "-C", repo, "worktree", "add", "-q", "-b", "feature", worktree)
    config = build_config("projects" => { repo => { "name" => "global-thing" } })

    Dir.chdir(worktree) do
      project = DevEnv::Project.load(config)
      assert_equal "global-thing", project.name
      assert_equal File.realpath(repo), File.realpath(project.root)
    end
  end
end
