# frozen_string_literal: true

require_relative "test_helper"

class DatabaseTest < Minitest::Test
  # Replaces subprocess execution, recording every command.
  def recording(db)
    calls = []
    db.define_singleton_method(:run) { |*cmd, **kwargs| calls << [cmd, kwargs]; true }
    db.define_singleton_method(:capture) { |*cmd| calls << [cmd, {}]; "" }
    calls
  end

  # Stands in for the server while a clone runs: canned answers to the three
  # questions clone_from asks, and a record of every client it invokes.
  # Tables are name => {bytes:, columns:}.
  def cloning(db, tables, &failure)
    calls = []
    answer = lambda do |cmd|
      sql = cmd.last.to_s
      next "CREATE TRIGGER ...;\n" if cmd.include?("--triggers")
      next "CREATE TABLE ...;\n" if cmd.first == "mysqldump"
      next tables.map { |name, table| "#{name}\t#{table.fetch(:columns)}" }.join("\n") if sql.include?("columns")
      next tables.map { |name, table| "#{name}\t#{table.fetch(:bytes)}" }.join("\n") if sql.include?("tables")

      ""
    end
    db.define_singleton_method(:capture!) do |*cmd, stdin: nil|
      calls << { cmd: cmd, stdin: stdin }
      failure&.call(stdin)
      answer.call(cmd)
    end
    calls
  end

  def inserts(calls) = calls.filter_map { |call| call[:stdin] if call[:stdin].to_s.include?("INSERT") }

  FLAGS = ["-h", "127.0.0.1", "-P", "3306", "-u", "sample_dev"].freeze

  def mysql = DevEnv::Database.for({ "adapter" => "mysql", "user" => "sample_dev" })

  def test_adapter_selection_urls_and_extra_names
    assert_instance_of DevEnv::Database::Postgres, DevEnv::Database.for(nil)
    assert_instance_of DevEnv::Database::Postgres, DevEnv::Database.for({ "adapter" => "postgresql" })
    assert_instance_of DevEnv::Database::MySQL, DevEnv::Database.for({ "adapter" => "mariadb" })
    assert_raises(DevEnv::Error) { DevEnv::Database.for({ "adapter" => "sqlite" }) }
    assert_raises(DevEnv::Error) { DevEnv::Database.for("mysql") }

    assert_equal "postgresql:///db", DevEnv::Database.for(nil).url("db")
    assert_equal "mysql2://127.0.0.1:3306/db", DevEnv::Database.for({ "adapter" => "mysql" }).url("db")
    tuned = DevEnv::Database.for({ "adapter" => "mysql", "user" => "sample_dev", "host" => "10.0.0.2", "port" => 3307 })
    assert_equal "mysql2://sample_dev@10.0.0.2:3307/db", tuned.url("db")

    db = DevEnv::Database.for({ "extra" => ["${DATABASE}_data_science"] })
    assert_equal ["dev_env_x_data_science"], db.extra_names({ "DATABASE" => "dev_env_x" })
    assert_equal [], DevEnv::Database.for(nil).extra_names({})
  end

  def test_resource_identity_tracks_the_server_but_not_credentials_or_adapter_aliases
    first = DevEnv::Database.for({ "adapter" => "mysql", "host" => "DB.EXAMPLE", "port" => "3307", "user" => "one" })
    same = DevEnv::Database.for({ "adapter" => "mariadb", "host" => "db.example", "port" => 3307, "user" => "two" })
    other = DevEnv::Database.for({ "adapter" => "mysql", "host" => "other.example", "port" => 3307 })

    assert_equal first.resource_identity("template"), same.resource_identity("template")
    refute_equal first.resource_identity("template"), other.resource_identity("template")
    refute_equal first.resource_identity("template"), first.resource_identity("another_template")

    # Postgres commands follow libpq's environment, so the endpoint variables
    # are part of the identity.
    previous_host = ENV["PGHOST"]
    ENV.delete("PGHOST")
    local = DevEnv::Database.for(nil).resource_identity("template")
    ENV["PGHOST"] = "db.example"
    refute_equal local, DevEnv::Database.for(nil).resource_identity("template")
  ensure
    ENV["PGHOST"] = previous_host
  end

  def test_postgres_lifecycle_commands_and_template_copy
    db = DevEnv::Database.for(nil)
    calls = recording(db)
    db.exists?("db")
    db.create("db")
    db.drop("db")
    db.clone_from("template", "target")

    assert_equal ["psql", "-tAc", "SELECT 1 FROM pg_database WHERE datname = 'db'"], calls[0].first
    assert_equal ["createdb", "db"], calls[1].first
    assert_equal ["dropdb", "--if-exists", "db"], calls[2].first
    # The empty database `up` already made has to go: the copy is what
    # creates the database, not something applied to an existing one.
    assert_equal ["dropdb", "--if-exists", "target"], calls[3].first
    assert_equal ["createdb", "--template", "template", "target"], calls[4].first
    assert calls.drop(1).all? { |_, kwargs| kwargs.fetch(:check, true) }
  end

  def test_mysql_lifecycle_commands_carry_connection_flags_and_are_checked
    db = mysql
    calls = recording(db)
    db.exists?("db")
    db.create("db")
    db.drop("db")

    # information_schema equality, not SHOW DATABASES LIKE, whose pattern
    # would treat the underscores in every generated name as wildcards.
    assert_equal ["mysql", *FLAGS, "--skip-column-names", "-e",
                  "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'db'"], calls[0].first
    assert_equal ["mysql", *FLAGS, "-e", "CREATE DATABASE `db`"], calls[1].first
    assert_equal ["mysql", *FLAGS, "-e", "DROP DATABASE IF EXISTS `db`"], calls[2].first
    assert calls.drop(1).all? { |_, kwargs| kwargs.fetch(:check, true) }
  end

  def test_mysql_clone_loads_schema_then_insertable_rows_then_triggers
    db = mysql
    calls = cloning(db, { "films" => { bytes: 900, columns: "`id`,`title`" },
                          "people" => { bytes: 100, columns: "`id`,`name`" } })

    db.clone_from("template", "target", jobs: 2)

    dump = calls.find { |call| call[:cmd].first == "mysqldump" }
    assert_equal ["mysqldump", *FLAGS, "--no-data", "--skip-triggers", "--routines", "--events", "template"],
                 dump[:cmd]
    schema = calls.find { |call| call[:stdin].to_s.start_with?("CREATE TABLE") }
    assert_equal ["mysql", *FLAGS, "target"], schema[:cmd]

    # The schema is in place before any row is copied, and triggers are
    # installed only once the rows are in: a trigger fires for every row an
    # INSERT copies, so one installed with the schema would leave the clone
    # holding rows the template does not have.
    first_insert = calls.index { |call| call[:stdin].to_s.include?("INSERT") }
    triggers = calls.index { |call| call[:stdin].to_s.start_with?("CREATE TRIGGER") }
    assert_operator calls.index(schema), :<, first_insert
    assert_operator calls.rindex { |call| call[:stdin].to_s.include?("INSERT") }, :<, triggers
    assert_equal ["mysqldump", *FLAGS, "--no-create-info", "--no-data",
                  "--skip-routines", "--skip-events", "--triggers", "template"],
                 calls.find { |call| call[:cmd].include?("--triggers") }[:cmd]

    checks = "SET foreign_key_checks = 0, unique_checks = 0;"
    assert_equal ["#{checks}\nINSERT INTO `target`.`films` (`id`,`title`) " \
                  "SELECT `id`,`title` FROM `template`.`films`;",
                  "#{checks}\nINSERT INTO `target`.`people` (`id`,`name`) " \
                  "SELECT `id`,`name` FROM `template`.`people`;"], inserts(calls).sort

    # Base tables only (a view's rows write through to tables already
    # copied), and only non-generated columns (naming a generated column in
    # an INSERT is an error, so the statements cannot use SELECT *).
    query = calls.map { |call| call[:cmd].last.to_s }.find { |sql| sql.include?("information_schema.columns") }
    assert_includes query, "COALESCE(c.generation_expression, '') = ''"
    assert_includes query, "t.table_type = 'BASE TABLE'"
  end

  def test_mysql_clone_balances_the_tables_across_clients_by_size
    db = mysql
    calls = cloning(db, { "big" => { bytes: 100, columns: "`id`" },
                          "medium" => { bytes: 90, columns: "`id`" },
                          "small" => { bytes: 10, columns: "`id`" } })

    db.clone_from("template", "target", jobs: 2)

    # Largest first to whichever client has least: 100 | 90 + 10, not
    # 100 + 90 | 10, which would leave one client copying alone at the end.
    batches = inserts(calls).map { |sql| sql.scan(/FROM `template`\.`(\w+)`/).flatten }
    assert_equal [["big"], %w[medium small]], batches.sort
  end

  def test_mysql_clone_leaves_no_client_running_when_one_fails
    db = mysql
    calls = cloning(db, { "films" => { bytes: 900, columns: "`id`" },
                          "people" => { bytes: 100, columns: "`id`" } }) do |stdin|
      raise DevEnv::Error, "lost connection" if stdin.to_s.include?("INSERT INTO `target`.`films`")
    end

    assert_raises(DevEnv::Error) { db.clone_from("template", "target", jobs: 2) }

    # Both clients ran to completion before the failure surfaced: one still
    # writing into a database the caller is about to drop would fail that too.
    assert_equal 2, inserts(calls).size
  end

  def test_mysql_clone_refuses_a_template_with_no_tables
    db = mysql
    cloning(db, {})

    error = assert_raises(DevEnv::Error) { db.clone_from("template", "target") }
    assert_match(/seed template template has no tables/, error.message)
  end
end
