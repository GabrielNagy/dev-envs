# frozen_string_literal: true

module DevEnv
  # A seeded database kept on the server and cloned into each new
  # environment, so the cost of filling one is paid once a day rather than
  # once per environment.
  #
  # The project's own command fills it. A project that already knows how to
  # fetch and load its seed data keeps that where it is and points it at the
  # template through ${DATABASE_URL}; nothing about the dump's location,
  # format or freshness is repeated here.
  class SeedTemplate
    include Util

    VERSION = 2
    DEFAULT_MAX_AGE = "1d"
    UNITS = { "s" => 1, "m" => 60, "h" => 3_600, "d" => 86_400 }.freeze
    # The name is a database identifier interpolated into SQL, not a value
    # that can be bound, so it is held to what an unquoted identifier allows.
    NAME = /\A[A-Za-z0-9_$]+\z/

    attr_reader :database, :build

    def initialize(cache_dir:, project_root:, default_database:, spec:)
      raise Error, "seed_template in project configuration must be an object" unless spec.is_a?(Hash)

      @database = spec["database"] || default_database
      @build = spec["build"]
      @max_age = parse_max_age(spec.fetch("max_age", DEFAULT_MAX_AGE))
      validate_spec!

      @project_root = File.expand_path(project_root)
      @parent = File.join(cache_dir, "seed-templates")
    end

    # Clone the template into `name`, building it first when it is missing or
    # stale.
    #
    # One lock spans both. A rebuild dropping the template part way through
    # somebody else's clone would fail that environment, so concurrent `up`
    # commands clone one after another: a few seconds each, against an `up`
    # that rolls back.
    def clone_into(db, name, worktree, env, vars)
      resource = db.resource_identity(database)
      with_lock(resource) do
        rebuild(db, worktree, env, vars, resource) unless fresh?(db, resource)

        started_at = monotonic_time
        step "Cloning #{database} into #{name}"
        db.clone_from(database, name)
        ok "Cloned #{database} #{duration_tag(monotonic_time - started_at)}"
      end
    end

    private

    def rebuild(db, worktree, env, vars, resource)
      claim!(db, resource)
      started_at = monotonic_time
      step "Building seed template #{database}"

      # The attempt is recorded before its result, so a build that dies part
      # way leaves the template marked unusable. Left as it was, the previous
      # stamp would vouch for whatever the failed build had loaded and every
      # later environment would clone that.
      record(resource, "state" => "building")
      db.drop(database)
      db.create(database)
      sh(interpolate(build, vars), chdir: worktree, env: env)
      record(resource, "state" => "built", "built_at" => Time.now.utc.iso8601)

      ok "Built #{database} #{duration_tag(monotonic_time - started_at)}"
    end

    # Rebuilding drops the database first, so the name has to be one dev-env
    # is sure this project owns on this server. A matching resource and owner
    # in the stamp are that proof; without them, a changed endpoint, another
    # repository with the same project name, or a typo could destroy data.
    def claim!(db, resource)
      return unless db.exists?(database)
      stamp = read_stamp(resource)
      return if stamp&.values_at("project_root", "resource") == [@project_root, resource]

      raise Error, "#{database} already exists on this database server and this project does not own it. " \
                   "Drop it yourself, or point seed_template.database at a name this project owns."
    end

    def validate_spec!
      unless @build.is_a?(String) && !@build.strip.empty?
        raise Error, "seed_template.build in project configuration must be the command that fills the template"
      end
      unless @database.is_a?(String) && @database.match?(NAME)
        raise Error, "seed_template.database must name a database in letters, digits, underscores or $"
      end
    end

    def parse_max_age(value)
      match = /\A(\d+)\s*([smhd])?\z/.match(value.to_s.strip)
      raise Error, "seed_template.max_age in project configuration must look like 30m, 12h or 1d" unless match

      Integer(match[1]) * UNITS.fetch(match[2] || "s")
    end

    # A template built by a command that has since changed is as stale as one
    # built too long ago, so the command is part of what has to still match.
    def fresh?(db, resource)
      stamp = read_stamp(resource)
      return false unless stamp
      return false unless stamp.values_at("version", "project_root", "resource", "database", "build", "state") ==
                          [VERSION, @project_root, resource, database, build, "built"]
      return false unless db.exists?(database)

      Time.now.utc - Time.iso8601(stamp.fetch("built_at")) < @max_age
    rescue ArgumentError, KeyError, TypeError
      false
    end

    def read_stamp(resource)
      JSON.parse(File.read(stamp_path(resource)))
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    def record(resource, fields)
      stamp = { "version" => VERSION, "project_root" => @project_root, "resource" => resource,
                "database" => database, "build" => build }.merge(fields)
      atomic_write(stamp_path(resource), "#{JSON.pretty_generate(stamp)}\n")
    end

    def resource_key(resource) = Digest::SHA256.hexdigest(JSON.generate(resource))
    def stamp_path(resource) = File.join(@parent, "#{resource_key(resource)}.json")
    def lock_path(resource) = File.join(@parent, "#{resource_key(resource)}.lock")

    def with_lock(resource)
      path = lock_path(resource)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end
  end
end
