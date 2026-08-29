# frozen_string_literal: true

require_relative "test_helper"

class StoreTest < Minitest::Test
  include DevEnvTest

  def setup
    config = build_config
    FileUtils.mkdir_p([config.state_dir, config.run_dir])
    @store = DevEnv::Store.new(state_dir: config.state_dir, run_dir: config.run_dir)
  end

  def test_state_roundtrip_keys_and_delete
    assert_raises(DevEnv::Error) { @store.load("proj-dev1") }
    @store.save("proj-dev1", { "slot" => "dev1", "port" => 4001 })
    assert_equal ["proj-dev1"], @store.keys
    assert_equal 4001, @store.load("proj-dev1")["port"]
    @store.delete("proj-dev1")
    refute @store.exist?("proj-dev1")
  end

  def test_env_file_roundtrip
    assert_raises(DevEnv::Error) { @store.saved_env("proj-dev1") }
    @store.write_env("proj-dev1", { "PORT" => "4001", "DATABASE_URL" => "postgresql:///x" })
    assert_equal({ "PORT" => "4001", "DATABASE_URL" => "postgresql:///x" }, @store.saved_env("proj-dev1"))
  end

  def test_launcher_is_executable_and_execs_the_server
    @store.write_launcher("proj-dev1", "/work/tree", "bin/rails server -p 4001")
    script = File.read(@store.run_path("proj-dev1"))
    assert_includes script, "cd /work/tree || exit 1"
    assert_includes script, "exec bin/rails server -p 4001"
    assert File.executable?(@store.run_path("proj-dev1"))
  end
end
