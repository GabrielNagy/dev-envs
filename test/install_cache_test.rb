# frozen_string_literal: true

require_relative "test_helper"

class InstallCacheTest < Minitest::Test
  include DevEnvTest

  def setup
    @cache_dir = Dir.mktmpdir.tap { |dir| (@tmp_dirs ||= []) << dir }
    @project_root = Dir.mktmpdir.tap { |dir| @tmp_dirs << dir }
    @worktree = Dir.mktmpdir.tap { |dir| @tmp_dirs << dir }
    @spec = {
      "directory" => "node_modules",
      "key_files" => ["package.json", "packages/*/package.json", "yarn.lock", ".yarnrc"],
    }
    FileUtils.mkdir_p(File.join(@worktree, "packages", "app"))
    File.write(File.join(@worktree, "package.json"), "{\"private\":true}\n")
    File.write(File.join(@worktree, "packages", "app", "package.json"), "{\"name\":\"app\"}\n")
    File.write(File.join(@worktree, "yarn.lock"), "# yarn lockfile v1\n")
    File.write(File.join(@worktree, ".yarnrc"), "ignore-scripts true\n")
  end

  def cache(command: "yarn install")
    DevEnv::InstallCache.new(cache_dir: @cache_dir, project_root: @project_root,
                             worktree: @worktree, command: command, spec: @spec)
  end

  def write_module(contents)
    path = File.join(@worktree, "node_modules", "example", "index.js")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    path
  end

  def store(current = cache)
    result = nil
    capture_io { result = current.store }
    result
  end

  def restore(current = cache)
    result = nil
    capture_io { result = current.restore }
    result
  end

  def test_store_and_restore_use_an_independent_copy
    installed = write_module("installed\n")
    assert store
    cached = Dir.glob(File.join(@cache_dir, "**", "directory", "example", "index.js")).fetch(0)
    FileUtils.rm_rf(File.join(@worktree, "node_modules"))

    assert restore

    assert_equal "installed\n", File.read(installed)
    refute_equal File.stat(cached).ino, File.stat(installed).ino
  end

  def test_restore_requires_the_same_key_files_and_install_command
    write_module("installed\n")
    store
    FileUtils.rm_rf(File.join(@worktree, "node_modules"))

    File.write(File.join(@worktree, "packages", "app", "package.json"), "{\"name\":\"changed\"}\n")
    refute restore
    refute_path_exists File.join(@worktree, "node_modules")

    File.write(File.join(@worktree, "packages", "app", "package.json"), "{\"name\":\"app\"}\n")
    refute restore(cache(command: "yarn install --ignore-scripts"))
    refute_path_exists File.join(@worktree, "node_modules")
  end

  def test_store_replaces_the_previous_snapshot
    write_module("first\n")
    store

    File.write(File.join(@worktree, "yarn.lock"), "# yarn lockfile v1\nchanged\n")
    write_module("second\n")
    assert store
    FileUtils.rm_rf(File.join(@worktree, "node_modules"))

    assert restore
    assert_equal "second\n", File.read(File.join(@worktree, "node_modules", "example", "index.js"))
  end

  def test_a_cache_write_failure_does_not_fail_the_install
    write_module("installed\n")
    unusable_cache_dir = File.join(@cache_dir, "not-a-directory")
    File.write(unusable_cache_dir, "file\n")
    current = DevEnv::InstallCache.new(cache_dir: unusable_cache_dir, project_root: @project_root,
                                       worktree: @worktree, command: "yarn install", spec: @spec)

    _, err = capture_io { refute current.store }

    assert_includes err, "continuing without updating the install cache"
  end

  def test_rejects_a_directory_outside_the_worktree
    @spec["directory"] = "../shared"

    error = assert_raises(DevEnv::Error) { cache }

    assert_includes error.message, "install_cache.directory"
  end
end
