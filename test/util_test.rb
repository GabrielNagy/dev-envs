# frozen_string_literal: true

require_relative "test_helper"

# Not included: Util#run would shadow Minitest::Test#run. Exercised the same
# way the classes use it, via the module functions.
class UtilTest < Minitest::Test
  U = DevEnv::Util

  def test_slugify_normalizes_truncates_and_rejects_empty
    assert_equal "feature-x-1", U.slugify("Feature/X_1")
    assert_equal "a" * DevEnv::Util::MAX_LABEL, U.slugify("a" * 60)
    assert_raises(DevEnv::Error) { U.slugify("///") }
  end

  def test_interpolate_recurses_and_blanks_missing_vars
    vars = { "PORT" => "4000", "DOMAIN" => "d.example.com" }
    assert_equal "-p 4000", U.interpolate("-p ${PORT}", vars)
    assert_equal({ "h" => ["d.example.com"] }, U.interpolate({ "h" => ["${DOMAIN}"] }, vars))
    assert_equal "x", U.interpolate("x${MISSING}", vars)
    assert_equal 5, U.interpolate(5, vars)
  end

  def test_run_raises_on_failure_and_returns_success
    assert_raises(DevEnv::Error) { U.run("false", quiet: true) }
    refute U.run("false", check: false, quiet: true)
    out, = capture_io { assert U.run("true") }
    assert_includes out, "$ true"
    assert_match(/└─ done \[\d+(?:ms|(?:\.\d+)?s)\]/, out)

    failed_out, = capture_io { refute U.run("false", check: false) }
    assert_match(/└─ failed \[\d+(?:ms|(?:\.\d+)?s)\]/, failed_out)
  end

  def test_sh_runs_through_the_shell
    out, = capture_io { assert U.sh("true && true", chdir: Dir.pwd) }
    assert_includes out, "$ true && true"
    capture_io { assert_raises(DevEnv::Error) { U.sh("exit 3", chdir: Dir.pwd) } }
  end

  def test_capture_strips_output_and_swallows_stderr
    assert_equal "hi", U.capture("echo", "hi")
    assert_equal "", U.capture("sh", "-c", "echo oops >&2")
  end

  def test_atomic_write_replaces_complete_contents_and_preserves_or_sets_mode
    Dir.mktmpdir do |dir|
      path = File.join(dir, "state.json")
      File.write(path, "old")
      File.chmod(0o640, path)

      assert_equal 3, U.atomic_write(path, "new")
      assert_equal "new", File.read(path)
      assert_equal 0o640, File.stat(path).mode & 0o777
      assert_empty Dir.glob(File.join(dir, ".*.tmp"))

      U.atomic_write(path, "executable", mode: 0o700)
      assert_equal 0o700, File.stat(path).mode & 0o777
    end
  end

  def test_format_duration_uses_readable_units
    assert_equal "125ms", U.format_duration(0.125)
    assert_equal "1s", U.format_duration(1.0)
    assert_equal "1.3s", U.format_duration(1.26)
    assert_equal "1m 05s", U.format_duration(65)
    assert_equal "1h 02m 03s", U.format_duration(3_723)
  end

  def test_color_is_limited_to_terminals_and_honors_no_color
    terminal = Object.new
    terminal.define_singleton_method(:tty?) { true }
    redirected = Object.new
    redirected.define_singleton_method(:tty?) { false }
    previous = ENV.delete("NO_COLOR")

    assert_equal "\e[36mhello\e[0m", U.color("hello", U::CYAN, stream: terminal)
    assert_equal "hello", U.color("hello", U::CYAN, stream: redirected)
    ENV["NO_COLOR"] = "1"
    assert_equal "hello", U.color("hello", U::CYAN, stream: terminal)
  ensure
    previous ? ENV["NO_COLOR"] = previous : ENV.delete("NO_COLOR")
  end
end
