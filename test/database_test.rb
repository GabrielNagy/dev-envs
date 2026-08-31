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

  MYSQL_FLAGS = ["-h", "127.0.0.1", "-P", "3306", "-u", "sample_dev"].freeze

  def mysql_adapter = DevEnv::Database.for({ "adapter" => "mysql", "user" => "sample_dev" })

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

  def test_resource_identity_tracks_the_server_but_not_credentials_or_adapter_aliases
    first = DevEnv::Database.for({ "adapter" => "mysql", "host" => "DB.EXAMPLE", "port" => "3307", "user" => "one" })
    same = DevEnv::Database.for({ "adapter" => "mariadb", "host" => "db.example", "port" => 3307, "user" => "two" })
    other = DevEnv::Database.for({ "adapter" => "mysql", "host" => "other.example", "port" => 3307 })

    assert_equal first.resource_identity("template"), same.resource_identity("template")
    refute_equal first.resource_identity("template"), other.resource_identity("template")
    refute_equal first.resource_identity("template"), first.resource_identity("another_template")

    previous_host = ENV["PGHOST"]
    ENV.delete("PGHOST")
    local = DevEnv::Database.for(nil).resource_identity("template")
    ENV["PGHOST"] = "db.example"
    refute_equal local, DevEnv::Database.for(nil).resource_identity("template")
  ensure
    ENV["PGHOST"] = previous_host
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

  def test_drop_and_restore_commands_are_checked
    [DevEnv::Database.for(nil), DevEnv::Database.for({ "adapter" => "mysql" })].each do |db|
      checks = []
      db.define_singleton_method(:run) { |*, **options| checks << options.fetch(:check, true); true }

      db.drop("db")
      db.restore("db", "/dump")

      assert_equal [true, true], checks
    end
  end
  def test_postgres_clones_through_its_own_template_copy
    db = DevEnv::Database.for(nil)
    calls = recording(db)

    db.clone_from("template", "target")

    # The empty database `up` already made has to go: the copy is what
    # creates the database, not something applied to an existing one.
    assert_equal ["dropdb", "--if-exists", "target"], calls[0]
    assert_equal ["createdb", "--template", "template", "target"], calls[1]
  end

  def test_mysql_clone_loads_the_template_schema_and_then_its_rows
    db = mysql_adapter
    calls = cloning(db, { "films" => { bytes: 900, columns: "`id`,`title`" },
                          "people" => { bytes: 100, columns: "`id`,`name`" } })

    db.clone_from("template", "target", jobs: 2)

    dump = calls.find { |call| call[:cmd].first == "mysqldump" }
    assert_equal ["mysqldump", *MYSQL_FLAGS, "--no-data", "--skip-triggers", "--routines", "--events", "template"],
                 dump[:cmd]

    schema = calls.find { |call| call[:stdin].to_s.start_with?("CREATE TABLE") }
    assert_equal ["mysql", *MYSQL_FLAGS, "target"], schema[:cmd]

    # The schema is in place before any row is copied.
    assert_operator calls.index(schema), :<, calls.index { |call| call[:stdin].to_s.include?("INSERT") }

    checks = "SET foreign_key_checks = 0, unique_checks = 0;"
    assert_equal ["#{checks}\nINSERT INTO `target`.`films` (`id`,`title`) " \
                  "SELECT `id`,`title` FROM `template`.`films`;",
                  "#{checks}\nINSERT INTO `target`.`people` (`id`,`name`) " \
                  "SELECT `id`,`name` FROM `template`.`people`;"], inserts(calls).sort
  end

  def test_mysql_clone_asks_only_for_columns_it_can_insert_into
    db = mysql_adapter
    calls = cloning(db, { "films" => { bytes: 1, columns: "`id`" } })

    db.clone_from("template", "target", jobs: 1)

    # A generated column is computed from the row's others, so naming one in
    # an INSERT is an error and the statements cannot use SELECT *. Checking
    # its expression, rather than EXTRA, keeps ordinary MySQL 8 columns marked
    # DEFAULT_GENERATED so their existing values are copied too.
    query = calls.map { |call| call[:cmd].last.to_s }.find { |sql| sql.include?("information_schema.columns") }
    assert_includes query, "COALESCE(c.generation_expression, '') = ''"
    refute_includes query, "c.extra"
    assert_includes query, "c.table_schema = 'template'"

    # Base tables only. information_schema lists a view's columns the same
    # way, and inserting into an updatable view writes its rows through to a
    # base table that has already been copied.
    assert_includes query, "t.table_type = 'BASE TABLE'"
  end

  def test_mysql_clone_installs_triggers_only_once_the_rows_are_in
    db = mysql_adapter
    calls = cloning(db, { "films" => { bytes: 1, columns: "`id`" } })

    db.clone_from("template", "target", jobs: 1)

    # A trigger fires for every row an INSERT copies, so one installed with
    # the schema would leave the clone holding rows the template does not.
    triggers = calls.find { |call| call[:cmd].include?("--triggers") }
    assert_equal ["mysqldump", *MYSQL_FLAGS, "--no-create-info", "--no-data",
                  "--skip-routines", "--skip-events", "--triggers", "template"], triggers[:cmd]

    loaded = calls.index { |call| call[:stdin].to_s.start_with?("CREATE TRIGGER") }
    assert_operator calls.rindex { |call| call[:stdin].to_s.include?("INSERT") }, :<, loaded
  end

  def test_mysql_clone_balances_the_tables_across_clients_by_size
    db = mysql_adapter
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
    db = mysql_adapter
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
    db = mysql_adapter
    cloning(db, {})

    error = assert_raises(DevEnv::Error) { db.clone_from("template", "target") }
    assert_match(/seed template template has no tables/, error.message)
  end
end
