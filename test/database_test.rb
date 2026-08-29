# frozen_string_literal: true

require_relative "test_helper"

class DatabaseTest < Minitest::Test
  # Replaces subprocess execution on one adapter, recording every command.
  def recording(db)
    calls = []
    db.define_singleton_method(:run) { |*cmd, **| calls << cmd; true }
    db.define_singleton_method(:capture) { |*cmd| calls << cmd; "" }
    calls
  end

  def test_adapter_selection_defaults_aliases_and_validation
    assert_instance_of DevEnv::Database::Postgres, DevEnv::Database.for(nil)
    assert_instance_of DevEnv::Database::Postgres, DevEnv::Database.for({})
    assert_instance_of DevEnv::Database::Postgres, DevEnv::Database.for({ "adapter" => "postgresql" })
    assert_instance_of DevEnv::Database::MySQL, DevEnv::Database.for({ "adapter" => "mysql" })
    assert_instance_of DevEnv::Database::MySQL, DevEnv::Database.for({ "adapter" => "mariadb" })
    assert_raises(DevEnv::Error) { DevEnv::Database.for({ "adapter" => "sqlite" }) }
    assert_raises(DevEnv::Error) { DevEnv::Database.for("mysql") }
  end

  def test_urls_and_dump_extensions
    assert_equal "postgresql:///db", DevEnv::Database.for(nil).url("db")
    assert_equal ".pdump", DevEnv::Database.for(nil).dump_extension

    mysql = DevEnv::Database.for({ "adapter" => "mysql" })
    assert_equal "mysql2://127.0.0.1:3306/db", mysql.url("db")
    assert_equal ".sql", mysql.dump_extension

    tuned = DevEnv::Database.for({ "adapter" => "mysql", "user" => "sample_dev", "host" => "10.0.0.2", "port" => 3307 })
    assert_equal "mysql2://sample_dev@10.0.0.2:3307/db", tuned.url("db")
  end

  def test_extra_names_interpolate_like_commands
    db = DevEnv::Database.for({ "adapter" => "mysql", "extra" => ["${DATABASE}_data_science"] })
    assert_equal ["dev_env_x_data_science"], db.extra_names({ "DATABASE" => "dev_env_x" })
    assert_equal [], DevEnv::Database.for(nil).extra_names({})
  end

  def test_postgres_lifecycle_commands
    db = DevEnv::Database.for(nil)
    calls = recording(db)
    db.exists?("db")
    db.create("db")
    db.drop("db")
    db.restore("db", "/dumps/seed.pdump")

    assert_equal ["psql", "-tAc", "SELECT 1 FROM pg_database WHERE datname = 'db'"], calls[0]
    assert_equal ["createdb", "db"], calls[1]
    assert_equal ["dropdb", "--if-exists", "db"], calls[2]
    assert_equal ["pg_restore", "--no-owner", "--no-acl", "-d", "db", "/dumps/seed.pdump"], calls[3]
  end

  def test_mysql_lifecycle_commands_carry_connection_flags
    db = DevEnv::Database.for({ "adapter" => "mariadb", "user" => "sample_dev" })
    calls = recording(db)
    db.exists?("db")
    db.create("db")
    db.drop("db")
    db.restore("db", "/dumps/seed.sql")

    flags = ["-h", "127.0.0.1", "-P", "3306", "-u", "sample_dev"]
    assert_equal ["mysql", *flags, "--skip-column-names", "-e",
                  "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'db'"], calls[0]
    assert_equal ["mysql", *flags, "-e", "CREATE DATABASE `db`"], calls[1]
    assert_equal ["mysql", *flags, "-e", "DROP DATABASE IF EXISTS `db`"], calls[2]
    assert_equal ["sh", "-c", "mysql #{flags.join(' ')} db < /dumps/seed.sql"], calls[3]
  end
end
