# frozen_string_literal: true

require_relative "test_helper"

class SecretsTest < Minitest::Test
  include DevEnvTest

  def setup
    @dir = Dir.mktmpdir.tap { |d| (@tmp_dirs ||= []) << d }
    @secrets = DevEnv::Secrets.new(@dir)
  end

  def test_password_persists_across_calls_with_restricted_mode
    refute @secrets.password?("proj-dev1")
    password = @secrets.password_for("proj-dev1")
    assert_equal 16, password.length
    assert_equal password, @secrets.password_for("proj-dev1")
    assert @secrets.password?("proj-dev1")
    assert_equal 0o600, File.stat(File.join(@dir, "proj-dev1.password")).mode & 0o777
  end

  def test_hostname_alias_is_lowercase_and_stable
    aka = @secrets.hostname_alias_for("proj-dev1")
    assert_match(/\A[a-z0-9]{8}\z/, aka)
    assert_equal aka, @secrets.hostname_alias_for("proj-dev1")
  end
end
