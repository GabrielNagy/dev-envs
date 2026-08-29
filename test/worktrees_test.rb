# frozen_string_literal: true

require_relative "test_helper"

class WorktreesTest < Minitest::Test
  include DevEnvTest

  def setup
    @config = build_config
    @repo = Dir.mktmpdir.tap { |d| (@tmp_dirs ||= []) << d }
    system("git", "init", "-q", "-b", "main", @repo)
    system("git", "-C", @repo, "-c", "user.email=t@t", "-c", "user.name=t",
           "commit", "-q", "--allow-empty", "-m", "init")
    @project = build_project(@config,
                             { "name" => "proj",
                               "link_from_root" => [".env.key"],
                               "worktree_files" => { "config/local.rb" => "domain '${DOMAIN}'" } },
                             root: @repo)
    @worktrees = DevEnv::Worktrees.new(@project)
    @path = File.join(Dir.mktmpdir.tap { @tmp_dirs << _1 }, "wt-feature")
  end

  def create_worktree(branch = "feature", base = "main")
    capture_subprocess_io { @worktrees.create(@path, branch, base) }
  end

  def test_create_from_base_then_find_verify_and_remove
    assert_nil @worktrees.existing_for("feature")
    create_worktree
    assert_equal @path, File.realpath(@worktrees.existing_for("feature"))

    @worktrees.verify_adopted!(@path, "feature")
    error = assert_raises(DevEnv::Error) { @worktrees.verify_adopted!(@path, "other") }
    assert_match(/is on "feature", not "other"/, error.message)
    assert_raises(DevEnv::Error) { @worktrees.verify_adopted!(Dir.mktmpdir.tap { @tmp_dirs << _1 }, "feature") }

    capture_subprocess_io { assert_raises(DevEnv::Error) { @worktrees.create(@path, "feature", "main") } }

    capture_subprocess_io { @worktrees.remove(@path, quiet: true) }
    refute Dir.exist?(@path)
  end

  def test_write_files_links_writes_and_excludes
    File.write(File.join(@repo, ".env.key"), "sekret")
    create_worktree

    capture_io { @worktrees.write_files(@path, "pkliinp6.proj.example.com") }

    assert_equal File.join(@repo, ".env.key"), File.readlink(File.join(@path, ".env.key"))
    assert_equal "domain 'pkliinp6.proj.example.com'\n", File.read(File.join(@path, "config/local.rb"))
    assert_includes File.read(File.join(@repo, ".git", "info", "exclude")), "config/local.rb"

    # Writing into the primary checkout itself must not clobber the real file.
    capture_io { @worktrees.write_files(@repo, "pkliinp6.proj.example.com") }
    refute File.symlink?(File.join(@repo, ".env.key"))
    assert_equal "sekret", File.read(File.join(@repo, ".env.key"))
  end
end
