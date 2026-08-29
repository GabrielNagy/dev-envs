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
end
