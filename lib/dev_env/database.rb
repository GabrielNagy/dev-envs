# frozen_string_literal: true

module DevEnv
  # The database engine behind each environment: postgres unless project
  # configuration declares {"database": {"adapter": "mysql"}}. The adapter
  # owns everything engine-specific — existence checks, create/drop, dump
  # restore and the default DATABASE_URL — so nothing else needs to branch on
  # the engine.
  class Database
    include Util

    def self.for(settings)
      settings ||= {}
      raise Error, "database in project configuration must be an object" unless settings.is_a?(Hash)
      adapter = settings.fetch("adapter", "postgres")
      case adapter
      when "postgres", "postgresql" then Postgres.new(settings)
      when "mysql", "mariadb"       then MySQL.new(settings)
      else raise Error, "unknown database adapter #{adapter.inspect} — postgres or mysql"
      end
    end

    def initialize(settings)
      @settings = settings
    end

    # Databases beyond the primary — {"extra": ["${DATABASE}_data_science"]} —
    # created on `up` and dropped on `down` alongside it, so a project needing
    # more than one database does not have to create and clean them up itself.
    def extra_names(vars) = interpolate(Array(@settings["extra"]), vars)

    class Postgres < Database
      def dump_extension = ".pdump"

      def exists?(name) = capture("psql", "-tAc", "SELECT 1 FROM pg_database WHERE datname = '#{name}'") == "1"
      def create(name)  = run("createdb", name)
      def drop(name, quiet: false) = run("dropdb", "--if-exists", name, quiet: quiet)

      def restore(name, dump) = run("pg_restore", "--no-owner", "--no-acl", "-d", name, dump)

      # Postgres copies a database for us: CREATE DATABASE ... TEMPLATE
      # duplicates the source's files. It refuses while another session holds
      # the template open, and none does, since an environment reads the
      # template only while it is being built. The copy is what creates the
      # database, so the empty one `up` has already made goes first.
      def clone_from(template, name, **)
        drop(name)
        run("createdb", "--template", template, name)
      end

      def url(name) = "postgresql:///#{name}"

      # Identifies the physical database resource for ownership records and
      # locks. PostgreSQL uses its local connection defaults; include the
      # libpq endpoint variables that can redirect those commands so changing
      # one cannot make an old ownership record authorize a different server.
      def resource_identity(name)
        endpoint = %w[PGHOST PGHOSTADDR PGPORT PGSERVICE PGSERVICEFILE].to_h do |key|
          [key, ENV[key]]
        end.compact
        { "adapter" => "postgres", "endpoint" => endpoint, "database" => name }
      end
    end

    class MySQL < Database
      # How many clients copy rows at once when cloning a seed template.
      # Measured against a 1.5GB template on 16 cores, eight was where the
      # copy stopped getting faster: what remains is the template's schema,
      # which the server applies serially however the rows are divided.
      CLONE_JOBS = 8

      def dump_extension = ".sql"

      # information_schema equality rather than SHOW DATABASES LIKE, whose
      # pattern would treat the underscores in every generated name as
      # wildcards.
      def exists?(name)
        query = "SELECT schema_name FROM information_schema.schemata WHERE schema_name = '#{name}'"
        capture("mysql", *client_args, "--skip-column-names", "-e", query) == name
      end

      def create(name) = run("mysql", *client_args, "-e", "CREATE DATABASE `#{name}`")
      def drop(name, quiet: false) = run("mysql", *client_args, "-e", "DROP DATABASE IF EXISTS `#{name}`", quiet: quiet)

      # A MySQL seed dump is plain SQL, as mysqldump writes it.
      def restore(name, dump)
        run("sh", "-c", "mysql #{Shellwords.join(client_args)} #{name} < #{Shellwords.escape(dump)}")
      end

      # Recreate a seeded template as a new database on the same server. The
      # rows never leave the server, so this skips the serialize-and-parse
      # round trip that restoring a dump into every new environment pays:
      # against a 1.5GB template it takes around 10 seconds where the dump
      # takes 75. MariaDB offers nothing cheaper. It has no CREATE DATABASE
      # ... LIKE, and importing the template's tablespaces instead needs root
      # access to the data directory and loses AUTO_INCREMENT on the way in.
      def clone_from(template, name, jobs: CLONE_JOBS)
        columns = insertable_columns(template)
        if columns.empty?
          raise Error, "seed template #{template} has no tables: did its build command reach ${DATABASE_URL}?"
        end

        # Triggers come after the rows rather than with the schema. A trigger
        # fires for every row an INSERT copies, so one that writes an audit
        # row or recomputes a column would leave the clone holding data the
        # template does not have.
        feed(schema_of(template), database: name)
        run_batches(batches(template, name, columns, jobs))
        feed(triggers_of(template), database: name)
      end

      # mysql2:// is what Rails expects, which the defaults elsewhere also
      # happen to suit; a project wanting another scheme or query options
      # overrides DATABASE_URL in its env.
      def url(name) = "mysql2://#{user ? "#{user}@" : ''}#{host}:#{port}/#{name}"

      # Credentials do not distinguish a physical database: two projects
      # reaching the same server and name as different users must still share
      # one ownership record and lock.
      def resource_identity(name)
        { "adapter" => "mysql", "host" => host.to_s.downcase,
          "port" => Integer(port), "database" => name }
      end

      private

      def schema_of(template)
        capture!("mysqldump", *client_args, "--no-data", "--skip-triggers", "--routines", "--events", template)
      end

      def triggers_of(template)
        capture!("mysqldump", *client_args, "--no-create-info", "--no-data",
                 "--skip-routines", "--skip-events", "--triggers", template)
      end

      # Table => its insertable columns, back-quoted and in ordinal order.
      #
      # Base tables only. information_schema lists a view's columns the same
      # way, and inserting into an updatable view would write its rows
      # through to the base table that has already been copied.
      #
      # A generated column is computed from the row's other columns and
      # naming one in an INSERT is an error, so the statements cannot use
      # SELECT *.
      def insertable_columns(template)
        rows(<<~SQL)
          SET SESSION group_concat_max_len = 1048576;
          SELECT c.table_name, GROUP_CONCAT(CONCAT('`', c.column_name, '`') ORDER BY c.ordinal_position)
          FROM information_schema.columns c
          JOIN information_schema.tables t
            ON t.table_schema = c.table_schema AND t.table_name = c.table_name
          WHERE c.table_schema = '#{template}' AND t.table_type = 'BASE TABLE'
            AND COALESCE(c.generation_expression, '') = ''
          GROUP BY c.table_name
        SQL
      end

      def table_sizes(template)
        rows("SELECT table_name, COALESCE(data_length + index_length, 0) " \
             "FROM information_schema.tables " \
             "WHERE table_schema = '#{template}' AND table_type = 'BASE TABLE'")
          .transform_values(&:to_i)
      end

      # One statement list per client, the tables dealt out largest first to
      # whichever list is smallest so far. A handful of tables hold most of
      # the rows, so an even split by bytes is what keeps the largest from
      # still copying alone once every other client has finished.
      #
      # The template's rows already satisfy every constraint, and the lists
      # load tables in an order no foreign key follows, so both checks are
      # off: leaving them on would fail a child table loaded before its
      # parent and re-prove what the template already established.
      def batches(template, name, columns, jobs)
        sizes = table_sizes(template)
        buckets = Array.new(jobs) { { bytes: 0, statements: [] } }
        columns.sort_by { |table, _| [-sizes.fetch(table, 0), table] }.each do |table, list|
          bucket = buckets.min_by { |candidate| candidate[:bytes] }
          bucket[:bytes] += sizes.fetch(table, 0)
          bucket[:statements] <<
            "INSERT INTO `#{name}`.`#{table}` (#{list}) SELECT #{list} FROM `#{template}`.`#{table}`;"
        end
        buckets.reject { |bucket| bucket[:statements].empty? }
               .map { |bucket| ["SET foreign_key_checks = 0, unique_checks = 0;", *bucket[:statements]].join("\n") }
      end

      # Every client is joined before the first failure is raised: a batch
      # still writing into a database the caller is about to drop would fail
      # that rollback too.
      def run_batches(sql_batches)
        threads = sql_batches.map do |sql|
          Thread.new { feed(sql) }.tap { |thread| thread.report_on_exception = false }
        end
        failures = threads.filter_map do |thread|
          thread.join
          nil
        rescue StandardError => error
          error
        end
        raise failures.first if failures.any?
      end

      # Statements arrive on stdin rather than through -e: a clone naming
      # every table would otherwise stand in the process table in full, and a
      # large one would outgrow the argument limit.
      def feed(sql, database: nil)
        capture!("mysql", *client_args, *Array(database), stdin: sql)
      end

      # Batch output separates columns with a tab and escapes any tab inside
      # a value, so splitting on the first one recovers the pair intact.
      def rows(sql)
        capture!("mysql", *client_args, "--batch", "--skip-column-names", "-e", sql)
          .lines.filter_map { |line| line.chomp.split("\t", 2) if line.include?("\t") }.to_h
      end

      # TCP to loopback rather than the local socket, so the client used for
      # create/drop reaches the same server the DATABASE_URL names.
      def host = @settings.fetch("host", "127.0.0.1")
      def port = @settings.fetch("port", 3306)
      def user = @settings["user"]

      def client_args
        args = ["-h", host, "-P", port.to_s]
        args += ["-u", user] if user
        args
      end
    end
  end
end
