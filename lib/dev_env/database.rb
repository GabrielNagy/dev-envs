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

      def url(name) = "postgresql:///#{name}"
    end

    class MySQL < Database
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

      # mysql2:// is what Rails expects, which the defaults elsewhere also
      # happen to suit; a project wanting another scheme or query options
      # overrides DATABASE_URL in its env.
      def url(name) = "mysql2://#{user ? "#{user}@" : ''}#{host}:#{port}/#{name}"

      private

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
