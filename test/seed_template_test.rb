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

  # Clones once, collecting the build commands run and the environment each
  # was given. `fail_build` makes the project's command fail.
  def clone(current = template, db: FakeDatabase.new, fail_build: false)
    commands = []
    current.define_singleton_method(:sh) do |command, **options|
      commands << [command, options[:env]]
      raise DevEnv::Error, "command failed: #{command}" if fail_build
    end
    template_env = { "DATABASE" => current.database, "DATABASE_URL" => db.url(current.database) }
    vars = template_env.merge("WORKTREE" => @worktree)
    capture_io do
      current.clone_into(db, "dev_env_sample_4000_ab", @worktree, template_env, vars)
    end
    [commands, db]
  end

  def stamp_path = Dir.glob(File.join(@cache_dir, "seed-templates", "*.json")).fetch(0)
  def stamp = JSON.parse(File.read(stamp_path))

  def age_stamp(seconds)
    File.write(stamp_path, JSON.generate(stamp.merge("built_at" => (Time.now.utc - seconds).iso8601)))
  end

  def test_a_first_clone_builds_the_template_and_a_fresh_one_is_cloned_without_rebuilding
    commands, db = clone

    assert_equal ["dev_env_sample_template"], db.dropped
    assert_equal ["dev_env_sample_template"], db.created
    assert_equal [["dev_env_sample_template", "dev_env_sample_4000_ab"]], db.clones
    assert_equal ["load-seed --into mysql2://sample_dev@127.0.0.1:3306/dev_env_sample_template",
                  { "DATABASE" => "dev_env_sample_template",
                    "DATABASE_URL" => "mysql2://sample_dev@127.0.0.1:3306/dev_env_sample_template" }],
                 commands.fetch(0)

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

    # A failure after an earlier success invalidates the template too: the old
    # stamp no longer vouches for the database the failed build left behind.
    age_stamp(2 * 86_400)
    assert_raises(DevEnv::Error) { clone(db: db, fail_build: true) }
    assert_equal "building", stamp.fetch("state")
    commands, = clone(db: db)
    assert_equal 1, commands.size
  end

  def test_a_database_dev_env_did_not_build_is_never_dropped
    db = FakeDatabase.new(existing: true)
    error = assert_raises(DevEnv::Error) { clone(template(@spec.merge("database" => "production")), db: db) }
    assert_match(/this project does not own it/, error.message)
    assert_empty db.dropped

    # An ownership record for another server cannot authorize a drop either.
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

  def test_configuration_naming_defaults_and_validation
    assert_equal "dev_env_sample_template", template.database
    assert_equal "seed_bank", template(@spec.merge("database" => "seed_bank")).database
    { "90" => 90, "30m" => 1_800, "12h" => 43_200, "1d" => 86_400 }.each do |written, seconds|
      current = template(@spec.merge("max_age" => written))
      assert_equal seconds, current.instance_variable_get(:@max_age), written
    end

    assert_raises(DevEnv::Error) { template("build" => "") }
    assert_raises(DevEnv::Error) { template({}) }
    assert_raises(DevEnv::Error) { template("build" => "x", "database" => "one; DROP DATABASE two") }
    assert_raises(DevEnv::Error) { template("build" => "x", "max_age" => "a while") }
    assert_raises(DevEnv::Error) { template(["build"]) }
  end

  def test_a_project_configures_one_by_name_and_gets_the_default_database
    config = build_config
    project = build_project(config, { "name" => "sample", "seed_template" => @spec })

    assert_equal "dev_env_sample_template", project.seed_template.database
    assert_nil build_project(config, { "name" => "sample" }).seed_template
  end
end
