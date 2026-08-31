# frozen_string_literal: true

require_relative "test_helper"

class SeedTemplateTest < Minitest::Test
  include DevEnvTest

  # Records what building and cloning a template ask of the server.
  class FakeDatabase
    attr_reader :created, :dropped, :clones

    def initialize(existing: false, host: "127.0.0.1")
      @existing = existing
      @host = host
      @created = []
      @dropped = []
      @clones = []
    end

    def exists?(_name) = @existing
    def create(name) = (@created << name) && @existing = true

    def drop(name, **)
      @dropped << name
      @existing = false
    end

    def clone_from(template, name, **) = @clones << [template, name]
    def url(name) = "mysql2://sample_dev@127.0.0.1:3306/#{name}"
    def resource_identity(name) = { "adapter" => "mysql", "host" => @host, "port" => 3306,
                                    "database" => name }
  end

  def setup
    @cache_dir = Dir.mktmpdir.tap { |dir| (@tmp_dirs ||= []) << dir }
    @project_root = Dir.mktmpdir.tap { |dir| @tmp_dirs << dir }
    @worktree = Dir.mktmpdir.tap { |dir| @tmp_dirs << dir }
    @spec = { "build" => "load-seed --into ${DATABASE_URL}" }
  end

  def template(spec = @spec, project_root = @project_root)
    DevEnv::SeedTemplate.new(cache_dir: @cache_dir, project_root: project_root,
                             default_database: "dev_env_sample_template", spec: spec)
  end

  def template_context(current, db)
    vars = { "WORKTREE" => @worktree, "DATABASE" => current.database,
             "DATABASE_URL" => db.url(current.database) }
    [{ "DATABASE" => current.database, "DATABASE_URL" => db.url(current.database) }, vars]
  end

  # Clones once, collecting the build commands run and the environment each
  # was given. `fail_build` makes the project's command fail.
  def clone(current = template, db: FakeDatabase.new, env: nil, fail_build: false)
    commands = []
    current.define_singleton_method(:sh) do |command, **options|
      commands << [command, options[:env]]
      raise DevEnv::Error, "command failed: #{command}" if fail_build
    end
    template_env, vars = template_context(current, db)
    capture_io do
      current.clone_into(db, "dev_env_sample_4000_ab", @worktree, env || template_env, vars)
    end
    [commands, db]
  end

  def stamp_path = Dir.glob(File.join(@cache_dir, "seed-templates", "*.json")).fetch(0)
  def stamp = JSON.parse(File.read(stamp_path))

  def age_stamp(seconds)
    File.write(stamp_path, JSON.generate(stamp.merge("built_at" => (Time.now.utc - seconds).iso8601)))
  end

  def test_a_first_clone_builds_the_template_and_then_copies_it
    commands, db = clone

    assert_equal ["dev_env_sample_template"], db.dropped
    assert_equal ["dev_env_sample_template"], db.created
    assert_equal [["dev_env_sample_template", "dev_env_sample_4000_ab"]], db.clones
    assert_equal "load-seed --into mysql2://sample_dev@127.0.0.1:3306/dev_env_sample_template", commands.dig(0, 0)
  end

  def test_the_build_receives_the_template_environment
    commands, = clone

    assert_equal({ "DATABASE" => "dev_env_sample_template",
                   "DATABASE_URL" => "mysql2://sample_dev@127.0.0.1:3306/dev_env_sample_template" },
                 commands.dig(0, 1))
  end

  def test_a_fresh_template_is_cloned_without_being_rebuilt
    _, db = clone

    commands, = clone(db: db)

    assert_empty commands
    assert_equal ["dev_env_sample_template"], db.created
    assert_equal 2, db.clones.size
  end

  def test_a_failed_build_is_never_left_looking_fresh
    db = FakeDatabase.new
    assert_raises(DevEnv::Error) { clone(db: db, fail_build: true) }

    assert_equal "building", stamp.fetch("state")
    refute db.clones.any?, "a template that failed to build must not be cloned"

    # The next run rebuilds rather than trusting what the failure left behind.
    commands, = clone(db: db)
    assert_equal 1, commands.size
    assert_equal "built", stamp.fetch("state")
  end

  def test_a_build_that_fails_after_an_earlier_success_invalidates_the_template
    _, db = clone
    assert_equal "built", stamp.fetch("state")

    age_stamp(2 * 86_400)
    assert_raises(DevEnv::Error) { clone(db: db, fail_build: true) }

    # The stamp from the successful build no longer vouches for the database
    # the failed one left, even though that database now exists.
    assert_equal "building", stamp.fetch("state")
    commands, = clone(db: db)
    assert_equal 1, commands.size
  end

  def test_a_database_dev_env_did_not_build_is_never_dropped
    db = FakeDatabase.new(existing: true)

    error = assert_raises(DevEnv::Error) { clone(template(@spec.merge("database" => "production")), db: db) }

    assert_match(/this project does not own it/, error.message)
    assert_empty db.dropped
  end

  def test_an_ownership_record_for_another_server_cannot_authorize_a_drop
    clone(db: FakeDatabase.new(host: "old.example"))
    new_server = FakeDatabase.new(existing: true, host: "new.example")

    error = assert_raises(DevEnv::Error) { clone(db: new_server) }

    assert_match(/this project does not own it/, error.message)
    assert_empty new_server.dropped
  end

  def test_two_projects_sharing_one_database_share_a_lock_and_only_the_owner_can_use_it
    other_root = Dir.mktmpdir.tap { |dir| @tmp_dirs << dir }
    owner = template
    contender = template(@spec, other_root)
    db = FakeDatabase.new
    resource = db.resource_identity(owner.database)
    assert_equal owner.send(:lock_path, resource), contender.send(:lock_path, resource)

    clone(owner, db: db)
    error = assert_raises(DevEnv::Error) { clone(contender, db: db) }

    assert_match(/this project does not own it/, error.message)
    assert_equal ["dev_env_sample_template"], db.dropped
    assert_equal [["dev_env_sample_template", "dev_env_sample_4000_ab"]], db.clones
  end

  def test_a_template_older_than_max_age_is_rebuilt
    spec = @spec.merge("max_age" => "12h")
    _, db = clone(template(spec))

    age_stamp(11 * 3_600)
    assert_empty clone(template(spec), db: db).first

    age_stamp(13 * 3_600)
    assert_equal 1, clone(template(spec), db: db).first.size
  end

  def test_a_changed_build_command_makes_the_template_stale
    _, db = clone

    commands, = clone(template(@spec.merge("build" => "load-seed --lightweight ${DATABASE}")), db: db)

    assert_equal ["load-seed --lightweight dev_env_sample_template"], commands.map(&:first)
  end

  def test_a_template_dropped_behind_dev_envs_back_is_rebuilt
    clone

    assert_equal 1, clone(db: FakeDatabase.new(existing: false)).first.size
  end

  def test_the_database_can_be_named_and_defaults_to_the_project
    _, db = clone(template(@spec.merge("database" => "seed_bank")))
    assert_equal ["seed_bank"], db.created

    assert_equal "dev_env_sample_template", template.database
  end

  def test_rejects_configuration_that_could_not_build_or_be_named
    assert_raises(DevEnv::Error) { template("build" => "") }
    assert_raises(DevEnv::Error) { template({}) }
    assert_raises(DevEnv::Error) { template("build" => "x", "database" => "one; DROP DATABASE two") }
    assert_raises(DevEnv::Error) { template("build" => "x", "max_age" => "a while") }
    assert_raises(DevEnv::Error) { template(["build"]) }
  end

  def test_max_age_accepts_the_usual_units
    { "90" => 90, "30m" => 1_800, "12h" => 43_200, "1d" => 86_400 }.each do |written, seconds|
      current = template(@spec.merge("max_age" => written))
      assert_equal seconds, current.instance_variable_get(:@max_age), written
    end
  end

  def test_a_project_configures_one_by_name_and_gets_the_default_database
    config = build_config
    project = build_project(config, { "name" => "sample", "seed_template" => @spec })

    assert_equal "dev_env_sample_template", project.seed_template.database
    assert_nil build_project(config, { "name" => "sample" }).seed_template
  end
end
