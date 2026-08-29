# frozen_string_literal: true

require_relative "test_helper"

class SecretsTest < Minitest::Test
  include DevEnvTest

  KEY = "proj--feature--4001"

  def setup
    @dir = Dir.mktmpdir.tap { |d| (@tmp_dirs ||= []) << d }
    @secrets = DevEnv::Secrets.new(@dir)
  end

  def test_password_persists_across_calls_with_restricted_mode
    refute @secrets.password?(KEY)
    password = @secrets.password_for(KEY)
    assert_equal 16, password.length
    assert_equal password, @secrets.password_for(KEY)
    assert @secrets.password?(KEY)
    assert_equal 0o600, File.stat(File.join(@dir, "#{KEY}.password")).mode & 0o777
  end

  def test_delete_password_ends_the_secret_lifetime
    @secrets.password_for(KEY)
    @secrets.delete_password(KEY)
    refute @secrets.password?(KEY)
    refute_path_exists File.join(@dir, "#{KEY}.password")
    @secrets.delete_password(KEY) # idempotent
  end
end
