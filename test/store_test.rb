# frozen_string_literal: true

require_relative "test_helper"

class StoreTest < Minitest::Test
  include DevEnvTest

  def setup
    @config = build_config
    FileUtils.mkdir_p([@config.state_dir, @config.run_dir])
    @store = DevEnv::Store.new(state_dir: @config.state_dir, run_dir: @config.run_dir,
                               secret_dir: @config.secret_dir)
  end

  KEY = "proj--feature--epxrnilj"

  def test_state_roundtrip_keys_and_delete_covering_every_artifact
    assert_raises(DevEnv::Error) { @store.load(KEY) }
    state = { "branch" => "feature", "port" => 4001 }
    @store.save(KEY, state)
    assert_equal [KEY], @store.keys
    assert_equal [state], @store.states
    assert_equal 4001, @store.load(KEY)["port"]

    @store.password_for(KEY)
    @store.delete(KEY)
    refute @store.exist?(KEY)
    refute @store.password?(KEY), "delete ends the password's lifetime with the record"
    @store.delete(KEY) # idempotent
  end

  def test_env_file_roundtrip
    assert_raises(DevEnv::Error) { @store.saved_env(KEY) }
    @store.write_env(KEY, { "PORT" => "4001", "DATABASE_URL" => "mysql2:///x" })
    assert_equal({ "PORT" => "4001", "DATABASE_URL" => "mysql2:///x" }, @store.saved_env(KEY))
  end

  def test_launcher_is_executable_and_execs_the_server
    @store.write_launcher(KEY, "/work/tree", "bin/rails server -p 4001")
    script = File.read(@store.run_path(KEY))
    assert_includes script, "cd /work/tree || exit 1"
    assert_includes script, "exec bin/rails server -p 4001"
    assert File.executable?(@store.run_path(KEY))
  end

  def test_password_persists_across_calls_with_restricted_mode
    refute @store.password?(KEY)
    password = @store.password_for(KEY)
    assert_equal 16, password.length
    assert_equal password, @store.password_for(KEY)
    assert_equal 0o600, File.stat(@store.password_path(KEY)).mode & 0o777
  end
end
