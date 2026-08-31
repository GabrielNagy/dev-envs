# frozen_string_literal: true

module DevEnv
  # Command-line entry point: parses options, wires the collaborators together
  # and owns the per-command workflows.
  class CLI
    include Util

    COMMANDS = %w[setup init up down list creds logs restart exec activate seed warm].freeze
    COMMAND_ALIASES = { "ls" => "list" }.freeze
    MACHINE_LIFECYCLE_COMMANDS = %w[setup warm].freeze

    USAGE = <<~TEXT
      Usage: dev-env <command> [options]

      Per machine:
        setup             Detect the public address, write the Caddy config and unit
      Environments and projects:
        init              Write a starter .dev-env.json
        up [branch]       Create an environment: worktree, database and service
        down [id]         Tear down an environment by its immutable ID
        down --all        Tear down every environment on this machine
        list (ls)         Show every environment
        creds [target]    Show the basic-auth credentials
        logs [target] [-f]
                          Show or follow service logs
        restart [target]  Restart the service
        exec [target] -c "command"
                          Run a command in the environment's worktree and env
        activate [target] Open a shell in the environment's worktree and env; exit to leave
        seed [target]     Rebuild the database from the seed dump
        warm              Rewrite recorded Caddy sites and pre-issue certificates

      A target is an environment ID or an exact branch in the current project.
      Inside an environment's worktree it may be omitted; `down` likewise
      infers its ID. `up` defaults to the currently checked-out branch.

      Environments are created on demand, each served at an HTTPS hostname whose
      leftmost label combines its immutable ID and the project name. Subdomains
      and which of them sit behind basic auth are declared in .dev-env.json
    TEXT

    def initialize(config: Config.new)
      @config = config
    end

    def start(argv)
      command = argv.shift
      command = COMMAND_ALIASES.fetch(command, command)
      if command == "help" && argv.any?
        raise Error, "Usage: dev-env help [command]" unless argv.one?

        requested = argv.shift
        command = COMMAND_ALIASES.fetch(requested, requested)
        argv << "--help"
      end
      help_requested = argv.one? && %w[-h --help].include?(argv.first)
      if command.nil? || %w[-h --help help].include?(command)
        puts USAGE
      elsif COMMANDS.include?(command)
        operation = proc do
          if !help_requested && @config.exist? && %w[creds warm].include?(command)
            Caddy.new(@config).ensure_certificate_configuration!
          end
          send("cmd_#{command}", argv)
        end
        if MACHINE_LIFECYCLE_COMMANDS.include?(command) && !help_requested
          with_machine_lifecycle_lock(&operation)
        else
          operation.call
        end
      else
        warn "#{color("Unknown command: #{command}", RED, stream: $stderr)}\n\n#{USAGE}"
        exit 1
      end
    rescue Error => error
      warn color("✗ #{error.message}", RED, stream: $stderr)
      exit 1
    end

    # ------------------------------------------------------------------ setup

    def cmd_setup(argv)
      parser = parse_options!(argv, "Usage: dev-env setup")
      reject_arguments!(argv, parser.banner)

      ip = capture("sh", "-c", "ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \\K[0-9.]+'")
      raise Error, "could not detect a public IPv4 address" if ip.empty?
      FileUtils.mkdir_p([@config.home, @config.state_dir, @config.dump_dir, @config.run_dir, @config.secret_dir])
      FileUtils.chmod(0o700, @config.secret_dir)

      unless @config.exist?
        atomic_write(@config.path, JSON.pretty_generate({
          "base_domain" => "example.com",
          "bind_ip" => ip,
          "port_range" => [4000, 4999],
          "acme_email" => "",
          "acme_dns_provider" => "",
        }) + "\n")
        ok "Wrote #{@config.path} — set base_domain, acme_email and acme_dns_provider " \
           "(e.g. \"route53\"), then re-run setup. Every project is served under one " \
           "base-domain wildcard certificate, so a DNS-01 provider is required and its credentials " \
           "must be available to Caddy."
        return
      end

      @config.acme_dns_provider # required; fail here rather than on the first `up`
      prepare_base_domain_change!
      if @config["bind_ip"] != ip
        note "config bind_ip is #{@config['bind_ip'].inspect} but this box answers on #{ip}"
      end

      step "Writing #{@config.caddyfile} (needs sudo)"
      output, status = Open3.capture2("sudo", "tee", @config.caddyfile,
                                     stdin_data: Caddy.new(@config).caddyfile_content)
      print output
      raise Error, "could not write #{@config.caddyfile}" unless status.success?

      run("sudo", "mkdir", "-p", @config.sites_dir)
      run("sudo", "chown", "#{ENV['USER']}:caddy", @config.sites_dir)
      run("sudo", "chmod", "2775", @config.sites_dir)
      Caddy.new(@config).ensure_wildcard_site
      run("sudo", "systemctl", "restart", "caddy")

      systemd.install
      ok "Ready. Add .dev-env.json to a project with: dev-env init"
    end

    def cmd_init(argv)
      parser = parse_options!(argv, "Usage: dev-env init")
      reject_arguments!(argv, parser.banner)

      root = capture("git", "rev-parse", "--show-toplevel")
      raise Error, "not inside a git repository" if root.empty?
      path = File.join(root, ".dev-env.json")
      raise Error, "#{path} already exists" if File.exist?(path)

      atomic_write(path, JSON.pretty_generate({
        "name" => File.basename(root),
        "commands" => {
          "install" => "bundle check || bundle install --jobs 4",
          "schema"  => "bin/rails db:schema:load",
          "migrate" => "bin/rails db:migrate",
          "server"  => "bin/rails server -b 127.0.0.1 -p ${PORT}",
        },
        "env" => { "RAILS_ENV" => "development" },
        "public" => false,
        "subdomains" => { "" => { "auth" => true }, "app" => { "auth" => true } },
        "after_restore" => [],
        "after_down" => [],
        "worktree_files" => {},
      }) + "\n")
      ok "Wrote #{path} — edit it to match this project, then: dev-env up <branch>"
    end

    # --------------------------------------------------------------------- up

    def cmd_up(argv)
      started_at = monotonic_time
      options = {}
      parser = parse_options!(argv, "Usage: dev-env up [branch] [options]") do |o|
        o.on("--seed PATH", "Dump to restore (default: project seed dump)") { |v| options[:seed] = v; options[:seed_given] = true }
        o.on("--no-seed", "Skip the dump; build the schema from migrations") { options[:no_seed] = true }
        o.on("--public", "Serve without HTTP basic auth (overrides .dev-env.json)") { options[:public] = true }
        o.on("--private", "Serve with configured basic auth (overrides .dev-env.json)") { options[:public] = false }
        o.on("--base REF", "Base ref when the branch does not exist (default: current branch)") { |v| options[:base] = v }
        o.on("--worktree PATH", "Serve an existing checkout instead of creating one") { |v| options[:worktree_path] = v }
      end
      checked_out_branch = current_branch
      branch = optional_argument!(argv, parser.banner) || checked_out_branch ||
               raise(Error, "#{parser.banner}\n  no branch given, and the current directory is not on a branch")
      options[:base] ||= checked_out_branch || capture("git", "rev-parse", "HEAD")
      options[:public] = project.public? unless options.key?(:public)

      with_environment_lifecycle_lock(project.root, project.name, branch) do
        Caddy.new(@config).ensure_certificate_configuration!
        bring_up_environment(branch, options, started_at)
      end
    end

    # ------------------------------------------------------------- lifecycle

    def cmd_down(argv)
      options = { worktree: true, database: true, all: false, force: false }
      parser = parse_options!(argv, "Usage: dev-env down [id] [options]") do |o|
        o.on("--all", "Tear down every recorded environment") { options[:all] = true }
        o.on("--keep-worktree", "Leave the git worktree in place") { options[:worktree] = false }
        o.on("--force", "Discard changes in a worktree created by dev-env") { options[:force] = true }
        o.on("--keep-database", "Leave the database in place") { options[:database] = false }
      end
      raise Error, "--force cannot be combined with --keep-worktree" if options[:force] && !options[:worktree]

      if options.delete(:all)
        raise Error, "#{parser.banner}\n  an environment ID cannot be combined with --all" unless argv.empty?
        return with_machine_lifecycle_lock { teardown_all_environments(options) }
      end

      id = optional_argument!(argv, parser.banner)
      key = if id.nil?
              implicit_key || raise(Error, "#{parser.banner}\n  no ID given, and #{Dir.pwd} is not inside an environment's worktree")
            else
              environment_key_for(id) || raise(Error, "no environment #{id.inspect} (try: dev-env list)")
            end
      state = store.load(key)
      with_environment_lifecycle_lock(state["project_root"], state["project"], state["branch"]) do
        teardown_environment(key, options)
      end
    end

    def teardown_all_environments(options)
      keys = store.keys
      return puts("No environments.") if keys.empty?

      failures = []
      keys.each do |key|
        teardown_environment(key, options, reload_caddy: false)
      rescue Error => error
        failures << [key, error]
        note "Failed to remove #{key}: #{error.message}"
      end
      with_caddy_lock { teardown_caddy.reload }
      unless failures.empty?
        raise Error, "failed to remove #{failures.length} environment#{'s' unless failures.one?}: " \
                     "#{failures.map(&:first).join(', ')}"
      end
      ok "All environments removed"
    end

    def teardown_environment(key, options, reload_caddy: true)
      state = store.load(key)
      if options[:worktree] && state["worktree_owned"] && !options[:force] && Worktrees.dirty?(state["worktree"])
        raise Error, "worktree #{state['worktree']} has uncommitted changes; rerun with --force to discard them, " \
                     "or --keep-worktree to preserve them"
      end

      failures = []
      try_cleanup(failures, "configure #{systemd.unit(key)}") do
        systemd.configure_process_manager(key, process_manager_for(state))
      end
      stopped = try_cleanup(failures, "stop #{systemd.unit(key)}") { stop_service!(key) }

      try_cleanup(failures, "remove Caddy site") do
        with_caddy_lock do
          step "Removing Caddy site"
          # The wildcard certificate is shared by every project, so removing this
          # hostname's route costs nothing at the next `up`.
          teardown_caddy.delete_site(key)
          teardown_caddy.reload if reload_caddy
        end
      end

      if stopped
        run_after_down(state, options)

        if options[:database]
          db = database_for(state)
          databases_for(state).each do |name|
            try_cleanup(failures, "drop database #{name}") do
              step "Dropping database #{name}"
              db.drop(name)
            end
          end
        end

        # Removal requires positive evidence that dev-env created this worktree;
        # discarding changes additionally requires the caller's explicit consent.
        owned = state["worktree_owned"]
        if !options[:worktree]
          note "Leaving worktree #{state['worktree']} (--keep-worktree)" if owned
        elsif owned
          try_cleanup(failures, "remove worktree #{state['worktree']}") do
            step "Removing worktree #{state['worktree']}"
            with_project_lock(state["project_root"]) do
              Worktrees.remove(state["worktree"], root: state["project_root"], force: options[:force])
            end
          end
        else
          note "Leaving worktree #{state['worktree']} — dev-env did not create it"
        end

        try_cleanup(failures, "remove systemd override") { systemd.configure_process_manager(key, nil) }
      else
        note "Service is still running; leaving its databases and worktree intact"
      end

      raise Error, "incomplete teardown; state kept: #{failures.join('; ')}" unless failures.empty?

      secrets.delete_password(key)
      store.delete(key)
      ok "#{state['project']}/#{state['branch']} removed"
    end

    def cmd_list(argv)
      parser = parse_options!(argv, "Usage: dev-env list")
      reject_arguments!(argv, parser.banner)

      states = store.states
      return puts("No environments.") if states.empty?

      rows = states.map do |state|
        key = state["key"]
        [state["id"].to_s, state["project"].to_s, state["branch"].to_s,
         state["port"].to_s, systemd.status(key), "https://#{state['domain']}"]
      end
      headers = %w[ID PROJECT BRANCH PORT STATUS URL]
      widths = headers.each_with_index.map { |h, i| ([h] + rows.map { |r| r[i] }).map(&:length).max }

      puts color(headers.each_with_index.map { |h, i| h.ljust(widths[i]) }.join("  "), BOLD)
      rows.each do |row|
        cells = row.each_with_index.map { |c, i| c.ljust(widths[i]) }
        cells[4] = color(cells[4], row[4] == "active" ? GREEN : RED)
        cells[5] = color(cells[5], CYAN)
        puts cells.join("  ")
      end
    end

    def cmd_creds(argv)
      parser = parse_options!(argv, "Usage: dev-env creds [target]")
      target = optional_argument!(argv, parser.banner)
      guarded = project.subdomains.select { |sub| sub["auth"] }
      return puts("No hostname for #{project.name} is behind basic auth.") if guarded.empty?

      key = target ? resolve(target) : implicit_key
      if key.nil?
        project_states.each do |state|
          next unless secrets.password?(state["key"])
          host = project.host_for(state["domain"], guarded.first["label"])
          puts "#{color(state['branch'], BOLD)}  #{color("https://#{host}", CYAN)}  " \
               "#{@config.basic_auth_user} / #{color(secrets.password_for(state['key']), YELLOW)}"
        end
        return
      end

      state = store.load(key)
      unless state["basic_auth"]
        return puts("#{state['project']}/#{state['branch']} is public; it has no basic-auth credentials.")
      end

      domain = state["domain"]
      guarded.each_with_index do |sub, index|
        label = index.zero? ? "URLs" : "".ljust(4)
        puts "#{color(label, BOLD)}     #{color("https://#{project.host_for(domain, sub['label'])}", CYAN)}"
      end
      puts "#{color('Username', BOLD)} #{@config.basic_auth_user}"
      puts "#{color('Password', BOLD)} #{color(secrets.password_for(key), YELLOW)}"
    end

    def cmd_logs(argv)
      follow = false
      parser = parse_options!(argv, "Usage: dev-env logs [target] [-f]") do |o|
        o.on("-f", "--follow", "Follow new log entries") { follow = true }
      end
      key = resolve_target(argv, parser.banner)
      exec("journalctl", "--user", "-u", systemd.unit(key), *("--follow" if follow))
    end

    def cmd_restart(argv)
      parser = parse_options!(argv, "Usage: dev-env restart [target]")
      key = resolve_target(argv, parser.banner)
      state = store.load(key)
      with_environment_lifecycle_lock(state["project_root"], state["project"], state["branch"]) do
        state = store.load(key)
        systemd.configure_process_manager(key, process_manager_for(state))
        systemd.systemctl("restart", systemd.unit(key))
        ok(wait_for_boot(state["port"]) ? "Restarted #{key}" : "Restarted #{key}, not answering yet")
      end
    end

    def cmd_exec(argv)
      command = nil
      parser = parse_options!(argv, "Usage: dev-env exec [target] -c \"command\"") do |o|
        o.on("-c COMMAND", "Command to run in the environment") { |v| command = v }
      end
      raise Error, parser.banner if command.to_s.empty?
      key = resolve_target(argv, parser.banner)
      worktree = store.load(key)["worktree"]
      system(store.saved_env(key), command, chdir: worktree)
      exit($?.exitstatus || 1)
    end

    # Spawns an interactive shell in the environment's worktree with its env
    # applied — the pipenv/poetry/nix `shell` pattern. Leaving is just `exit`.
    # PATH is left alone: the saved one exists only because systemd starts
    # units with a minimal PATH, and an interactive shell already has a
    # better one.
    def cmd_activate(argv)
      parser = parse_options!(argv, "Usage: dev-env activate [target]")
      key = resolve_target(argv, parser.banner)
      state = store.load(key)
      if nested_in_active_shell?
        # A child process cannot make its parent shell exit, so a shell
        # started here could only nest inside the active one. Refuse instead.
        raise Error, "already inside #{ENV['DEV_ENV_ACTIVE']} — `exit` first, or switch shells " \
                     "in place with `exec dev-env activate #{state['id']}`"
      end
      env = store.saved_env(key).except("PATH").merge("DEV_ENV_ACTIVE" => state["id"])
      ok "Entering #{state['id']} (#{state['worktree']}) — exit to leave"
      $stdout.flush # exec replaces the process before Ruby flushes buffered output
      exec(env, ENV.fetch("SHELL", "/bin/sh"), chdir: state["worktree"])
    end

    def cmd_seed(argv)
      options = {}
      parser = parse_options!(argv, "Usage: dev-env seed [target] [--seed PATH]") do |o|
        o.on("--seed PATH", "Dump to restore (default: project seed dump)") { |v| options[:seed] = v }
      end
      key = resolve_target(argv, parser.banner)
      state = store.load(key)
      with_environment_lifecycle_lock(state["project_root"], state["project"], state["branch"]) do
        Caddy.new(@config).ensure_certificate_configuration!
        state = store.load(key)
        dump = options[:seed] || project.default_dump
        raise Error, "seed dump not found: #{dump}" unless File.exist?(dump)

        vars = project.vars_for(state)
        app_env = project.app_env_for(vars)

        systemd.configure_process_manager(key, process_manager_for(state))
        stop_service!(key, command: "stop", message: "Stopping #{systemd.unit(key)} while the database is rebuilt")

        db = database_for(state)
        step "Recreating #{databases_for(state).join(', ')}"
        databases_for(state).each do |name|
          db.drop(name)
          db.create(name)
        end
        restore_dump(db, state["database"], dump, state["worktree"], app_env, vars)

        project_command(interpolate(project.commands, vars)["migrate"], "Running migrations", state["worktree"], app_env)

        systemd.systemctl("start", systemd.unit(key))
        ok(wait_for_boot(state["port"]) ? "Reseeded #{key}" : "Reseeded #{key}, not answering yet")
      end
    end

    def cmd_warm(argv)
      parser = parse_options!(argv, "Usage: dev-env warm")
      reject_arguments!(argv, parser.banner)

      caddy.ensure_wildcard_site
      # Every recorded environment's site file is rewritten, not just new
      # ones': a subdomain added to .dev-env.json after an environment came up
      # would otherwise go unserved until its next `up`.
      states = project_states
      states.each do |state|
        caddy.write_site(state["key"], state["domain"], state["port"],
                         state["basic_auth"] ? secrets.password_for(state["key"]) : nil)
      end
      caddy.reload

      # The wildcard certificate is fetched lazily on first request, and the
      # request that triggers issuance fails its own handshake, so retry until
      # one succeeds.
      failed = []
      states.each do |state|
        project.hosts_for(state["domain"]).each do |host|
          code = nil
          3.times do
            code = capture("curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "45", "https://#{host}")
            break unless code.to_i.zero?
            sleep 3
          end
          failed << host if code.to_i.zero?
          puts(code.to_i.zero? ? "  #{color('✗', RED)} #{host}" : "  #{color('✓', GREEN)} #{color(host, CYAN)} (#{code})")
        end
      end

      raise Error, "could not obtain certificates for: #{failed.join(', ')}" if failed.any?
      ok "Certificates warmed for #{project.name}"
    end

    private

    def parse_options!(argv, usage)
      parser = OptionParser.new(usage)
      yield parser if block_given?
      parser.parse!(argv)
      parser
    rescue OptionParser::ParseError => error
      raise Error, "#{error.message}\n#{parser}"
    end

    def reject_arguments!(argv, usage)
      raise Error, "#{usage}\n  unexpected argument: #{argv.first.inspect}" unless argv.empty?
    end

    def optional_argument!(argv, usage)
      argument = argv.shift
      reject_arguments!(argv, usage)
      argument
    end

    def try_cleanup(failures, description)
      yield
      true
    rescue Error, SystemCallError => error
      failures << "#{description}: #{error.message}"
      false
    end

    def stop_service!(key, command: "disable", message: "Stopping #{systemd.unit(key)}")
      step message
      args = command == "disable" ? ["disable", "--now"] : [command]
      systemd.systemctl(*args, systemd.unit(key), check: false)
      status = systemd.status(key)
      raise Error, "#{systemd.unit(key)} did not stop (#{status.empty? ? 'unknown' : status})" unless %w[inactive failed].include?(status)
    end

    # Targeted operations share the machine gate, then exclusively lock their
    # logical (repository, branch) environment. Machine-wide operations take
    # the gate exclusively, so setup and down --all still see a stable machine.
    def with_machine_lifecycle_lock(&block)
      with_file_lock(@config.lock_path, File::LOCK_EX,
                     conflict: "another dev-env lifecycle operation is running", &block)
    end

    def with_environment_lifecycle_lock(project_root, project_name, branch, &block)
      with_file_lock(@config.lock_path, File::LOCK_SH,
                     conflict: "a machine-wide dev-env operation is running") do
        root = project_root.to_s.empty? ? "project:#{project_name}" : File.expand_path(project_root)
        identity = "#{root}\0#{branch}"
        path = scoped_lock_path("environments", identity)
        with_file_lock(path, File::LOCK_EX,
                       conflict: "another dev-env operation is targeting #{project_name}/#{branch}",
                       record_owner: true, &block)
      end
    end

    # Shared resources are locked only while they are mutated. Different
    # environments can install, migrate and stop services in parallel.
    def with_caddy_lock(&block) =
      with_file_lock(scoped_lock_path("resources", "caddy"), File::LOCK_EX, &block)

    def with_project_lock(project_root, &block) =
      with_file_lock(scoped_lock_path("projects", File.expand_path(project_root)), File::LOCK_EX, &block)

    def scoped_lock_path(scope, identity)
      File.join(@config.home, "locks", scope, "#{Digest::SHA256.hexdigest(identity)}.lock")
    end

    def with_file_lock(path, mode, conflict: nil, record_owner: false)
      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
        flags = conflict ? mode | File::LOCK_NB : mode
        unless lock.flock(flags)
          lock.rewind
          owner = record_owner ? lock.read.strip : ""
          detail = owner.empty? ? "" : " (PID #{owner})"
          raise Error, "#{conflict}#{detail}"
        end

        if record_owner
          lock.truncate(0)
          lock.write(Process.pid.to_s)
          lock.flush
        end
        yield
      end
    end

    def project  = @project  ||= Project.load(@config)
    def store    = @store    ||= Store.new(state_dir: @config.state_dir, run_dir: @config.run_dir)
    def secrets  = @secrets  ||= Secrets.new(@config.secret_dir)
    def caddy    = @caddy    ||= Caddy.new(@config, project: project)
    def teardown_caddy = @teardown_caddy ||= Caddy.new(@config)
    def worktrees = @worktrees ||= Worktrees.new(project)
    def systemd   = @systemd   ||= Systemd.new(unit_path: @config.unit_path, env_dir: @config.state_dir, run_dir: @config.run_dir)
    def process_manager_for(state) = state["process_manager"]

    def database_for(state)  = Database.for(state["database_settings"])
    def databases_for(state) = state["databases"]

    # Project-defined teardown, mirroring after_restore. Runs after the service
    # stops and before anything is removed, so hooks still see the worktree,
    # database and saved environment. dev-env only removes what it created; a
    # project whose server pairs extra resources with an environment (a second
    # repository's worktree, say) cleans them up here. Hook failures warn but
    # never abort `down` — aborting halfway through teardown leaves a zombie.
    def run_after_down(state, options)
      hooks = state["after_down"]
      return if hooks.empty?
      env = store.saved_env(state["key"]).merge(
        "DEV_ENV_KEEP_WORKTREE" => (!options[:worktree]).to_s,
        "DEV_ENV_KEEP_DATABASE" => (!options[:database]).to_s,
      )
      chdir = [state["worktree"], state["project_root"], @config.home].find { |path| Dir.exist?(path.to_s) }
      hooks.each do |command|
        step "Running after_down: #{command}"
        sh(command, chdir: chdir, env: env, check: false) ||
          note("after_down command failed (continuing): #{command}")
      end
    rescue Error => error
      note "Skipping after_down commands: #{error.message}"
    end

    def prepare_base_domain_change!
      return if Caddy.new(@config).certificate_configuration_matches?

      count = store.states.length
      return if count.zero?
      raise Error, "base_domain cannot be changed while #{count} environment#{'s' unless count == 1} exist. " \
                   "Run `dev-env down --all`, then `dev-env setup`"
    end

    # Every recorded environment of the current project.
    def project_states
      store.states.select { |state| state["project"] == project.name }
    end

    # The ID is global because it names machine-wide artifacts. Hold its own
    # lock until the environment is recorded, so concurrent ups cannot reserve
    # the same random value before either state file exists.
    def with_environment_id_reservation
      loop do
        id = random_environment_id
        path = scoped_lock_path("ids", id)
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, File::RDWR | File::CREAT, 0o600) do |lock|
          next unless lock.flock(File::LOCK_EX | File::LOCK_NB)
          next if environment_key_for(id)

          return yield id
        end
      end
    end

    def random_environment_id = SecureRandom.random_number(36**8).to_s(36).rjust(8, "0")

    def bring_up_environment(branch, options, started_at)
      # The exact (project, branch) pair is the logical identity; only one
      # recorded environment may exist for it. The caller holds that identity's
      # lock, so another up or down cannot change the answer underneath us.
      if (existing = project_states.find { |state| state["branch"] == branch })
        raise Error, "#{project.name} already has an environment for #{branch.inspect} " \
                     "(https://#{existing['domain']}) — tear it down first: dev-env down #{existing['id']}"
      end

      with_environment_id_reservation do |id|
        key = project.key_for(branch, id)

        # Hold the port's socket open while the environment is prepared, so no
        # other process can claim it during a long build. Released immediately
        # before the service that binds it starts.
        reserved_ports = store.states.filter_map { |state| state["port"] }
        reservation = @config.reserve_port(reserved: reserved_ports)
        begin
          port = reservation.addr[1]
          database = project.database_for(port, id)
          # Git allows a branch in only one worktree, so a checkout that already exists is the one to
          # serve, not a conflict to refuse. An agent's worktree is the common case.
          worktree = File.expand_path(options[:worktree_path] || worktrees.existing_for(branch) ||
                                      File.join(project.worktree_root, "#{slugify(branch)}--#{id}"))
          worktrees.verify_adopted!(worktree, branch) if Dir.exist?(worktree)
          seed = options[:no_seed] ? nil : (options[:seed] || project.default_dump)

          state = {
            "id" => id, "key" => key, "project" => project.name, "branch" => branch,
            "domain" => project.domain_for(id),
            "port" => port, "database" => database, "worktree" => worktree,
            "project_root" => project.root,
            # Only a worktree this command created may be torn down by it, on rollback or on `down`.
            "worktree_owned" => !Dir.exist?(worktree),
            "basic_auth" => !options[:public] && project.subdomains.any? { |sub| sub["auth"] },
            "process_manager" => project.process_manager,
            "database_settings" => project.database_settings,
            "created_at" => Time.now.utc.iso8601,
          }
          # Persist the fully resolved commands so teardown by ID never depends
          # on the caller's current repository or a later config change.
          state["after_down"] = project.after_down.map { |command| interpolate(command, project.vars_for(state)) }
          # The primary plus any the project declares as extra, resolved here so
          # `down` drops exactly what `up` created even if .dev-env.json changes.
          state["databases"] = [database, *project.database.extra_names(project.vars_for(state))]

          FileUtils.mkdir_p([@config.state_dir, @config.run_dir, project.worktree_root])
          systemd.install unless systemd.installed?

          # A half-built environment is worse than none: undo whatever was
          # created if a later step fails, so a retry starts clean.
          rollback = []
          begin
            with_project_lock(project.root) do
              if state["worktree_owned"]
                step "Creating worktree #{worktree} for #{branch}"
                worktrees.create(worktree, branch, options[:base])
                rollback << ["remove worktree #{worktree}", lambda do
                  with_project_lock(project.root) { worktrees.remove(worktree, force: true, quiet: true) }
                end]
              else
                step "Using existing worktree #{worktree} for #{branch}"
              end
              worktrees.write_files(worktree, state["domain"])
            end

            db = database_for(state)
            state["databases"].each do |name|
              step "Creating database #{name}"
              raise Error, "database #{name} already exists" if db.exists?(name)
              db.create(name)
              rollback << ["drop database #{name}", -> { db.drop(name, quiet: true) }]
            end

            build_environment(state, seed, options, reservation)
          rescue StandardError => error
            note "Failed partway through — rolling back"
            failures = []
            stopped = try_cleanup(failures, "stop #{systemd.unit(key)}") { stop_service!(key) }
            if File.exist?(caddy.site_path(key))
              try_cleanup(failures, "remove Caddy site") do
                with_caddy_lock do
                  caddy.delete_site(key)
                  caddy.reload
                end
              end
            end
            rollback.reverse_each { |description, undo| try_cleanup(failures, description, &undo) } if stopped
            note "Service is still running; leaving its databases and worktree intact" unless stopped
            try_cleanup(failures, "remove systemd override") { systemd.configure_process_manager(key, nil) } if stopped
            try_cleanup(failures, "remove password") { secrets.delete_password(key) } if failures.empty?

            if failures.empty?
              store.delete(key)
            else
              store.save(key, state)
              note "Rollback incomplete (#{failures.join('; ')}); state kept for: dev-env down #{id}"
            end
            raise error
          end
        ensure
          reservation.close unless reservation.closed?
        end

        ok "#{project.name}/#{branch} is up"
        print_summary(key, total: monotonic_time - started_at)
      end
    end

    def build_environment(state, seed, options, reservation)
      key, branch, worktree, domain, port, database =
        state.values_at("key", "branch", "worktree", "domain", "port", "database")
      vars = project.vars_for(state)
      app_env = project.app_env_for(vars)
      commands = interpolate(project.commands, vars)

      install_dependencies(commands["install"], worktree, app_env)

      if seed && !File.exist?(seed)
        raise Error, "seed dump not found: #{seed}" if options[:seed_given]
        note "No seed dump at #{seed} — starting with an empty database"
        seed = nil
      end

      if seed
        restore_dump(database_for(state), database, seed, worktree, app_env, vars)
      else
        project_command(commands["schema"], "Loading schema", worktree, app_env)
      end
      project_command(commands["migrate"], "Running migrations", worktree, app_env)

      # state["basic_auth"] is false when no hostname sits behind auth: a
      # password is pointless then, and claiming otherwise in the summary
      # would be worse than saying nothing.
      password = state["basic_auth"] ? secrets.password_for(key) : nil

      step "Writing configuration"
      store.write_env(key, app_env)
      store.write_launcher(key, worktree, commands.fetch("server") { raise Error, "no commands.server in .dev-env.json" })
      systemd.configure_process_manager(key, state["process_manager"])

      # Route mutation and reload are one transaction. Without this short lock,
      # concurrent reloads could apply an older Caddy snapshot last.
      with_caddy_lock do
        caddy.ensure_wildcard_site
        caddy.write_site(key, domain, port, password)
        store.save(key, state)

        step "Reloading Caddy"
        caddy.reload
      end

      # State is persisted, so no other `up` can pick this port from it; only
      # now may the socket be released for the service to bind.
      reservation.close

      step "Starting #{systemd.unit(key)}"
      systemd.systemctl("enable", "--now", systemd.unit(key))

      note "Not answering on 127.0.0.1:#{port} yet — check: dev-env logs #{branch} -f" unless wait_for_boot(port)
    end

    def restore_dump(db, database, dump, worktree, app_env, vars)
      step "Restoring #{dump} into #{database}"
      db.restore(database, dump)

      project.after_restore.each { |command| sh(interpolate(command, vars), chdir: worktree, env: app_env) }
    end

    # Steps of `up` and `seed` defined by the project; each is optional.
    def install_dependencies(command, worktree, env)
      return unless command

      cache = if project.install_cache
                InstallCache.new(cache_dir: @config.cache_dir, project_root: project.root, worktree: worktree,
                                 command: command, spec: project.install_cache)
              end
      cache&.restore
      project_command(command, "Installing dependencies", worktree, env)
      cache&.store
    end

    def project_command(command, message, worktree, env)
      return unless command
      step message
      sh(command, chdir: worktree, env: env)
    end

    def wait_for_boot(port, timeout: 90)
      deadline = Time.now + timeout
      while Time.now < deadline
        begin
          Net::HTTP.start("127.0.0.1", port, open_timeout: 2, read_timeout: 5) { |http| http.get("/") }
          return true
        rescue StandardError
          sleep 2
        end
      end
      false
    end

    def print_summary(key, total:)
      state = store.load(key)
      puts
      project.subdomains.each_with_index do |sub, index|
        label = index.zero? ? "URLs" : ""
        open = state["basic_auth"] && !sub["auth"] ? "  #{color('(no auth)', YELLOW)}" : ""
        url = "https://#{project.host_for(state['domain'], sub['label'])}"
        puts "  #{color(label.ljust(10), BOLD)} #{color(url, CYAN)}#{open}"
      end
      auth = if state["basic_auth"]
               "#{@config.basic_auth_user} / #{color(secrets.password_for(key), YELLOW)}"
             else
               color("disabled", YELLOW)
             end
      adopted = state["worktree_owned"] ? "" : " #{color('(adopted; kept on down)', YELLOW)}"
      puts "  #{color('ID'.ljust(10), BOLD)} #{state['id']}"
      puts "  #{color('Basic auth', BOLD)} #{auth}"
      puts "  #{color('Worktree'.ljust(10), BOLD)} #{state['worktree']}#{adopted}"
      puts "  #{color('Database'.ljust(10), BOLD)} #{databases_for(state).join(', ')}  (port #{state['port']})"
      puts
      puts "  #{color('Logs'.ljust(10), BOLD)} #{color("dev-env logs #{state['branch']} -f", CYAN)}"
      puts "  #{color('Tear down'.ljust(10), BOLD)} #{color("dev-env down #{state['id']}", CYAN)}"
      puts
      puts "  #{color('Total'.ljust(10), BOLD)} #{duration_tag(total)}"
    end

    # Non-destructive commands accept either an immutable environment ID or an
    # exact branch belonging to the current project.
    def resolve(branch_or_id)
      key = environment_key_for(branch_or_id)
      return key if key
      match = project_states.find { |state| state["branch"] == branch_or_id }
      return match["key"] if match
      raise Error, "no environment #{branch_or_id.inspect} for #{project.name} (try: dev-env list)"
    end

    def environment_key_for(id)
      store.states.find { |state| state["id"] == id }&.fetch("key")
    end

    # The branch checked out in the current directory, so `up` run inside a
    # checkout can leave the branch off. Nil on a detached HEAD or outside a
    # repository.
    def current_branch
      branch = capture("git", "branch", "--show-current")
      branch unless branch.empty?
    end

    # The environment whose worktree contains the current directory, so a
    # command run from inside a served checkout can leave the branch off. A
    # shell entered with `dev-env activate` counts too, even after cd'ing
    # elsewhere.
    def implicit_key
      here = File.realpath(Dir.pwd)
      match = store.states.filter_map do |state|
        worktree = state["worktree"].to_s
        next if worktree.empty? || !Dir.exist?(worktree)
        root = File.realpath(worktree)
        [state["key"], root] if here == root || here.start_with?(root + File::SEPARATOR)
      end.max_by { |_, root| root.length }
      return match.first if match
      active = ENV["DEV_ENV_ACTIVE"].to_s
      environment_key_for(active) unless active.empty?
    end

    # The explicit target when given, otherwise the environment inferred from
    # the current directory.
    def resolve_target(argv, usage)
      target = optional_argument!(argv, usage)
      return resolve(target) if target

      implicit_key || raise(Error, "#{usage}\n  no target given, and #{Dir.pwd} is not inside an environment's worktree")
    end

    # True when this command was run inside an activated shell, as opposed to
    # exec'd in place of one. `exec` preserves the environment, so
    # DEV_ENV_ACTIVE alone cannot tell the two apart — but the parent process
    # can: run inside the activated shell, that shell is the parent; exec'd,
    # its parent is ours.
    def nested_in_active_shell?
      return false unless ENV["DEV_ENV_ACTIVE"]
      File.read("/proc/#{Process.ppid}/environ").split("\0").any? { |v| v.start_with?("DEV_ENV_ACTIVE=") }
    rescue SystemCallError, IOError
      true # cannot prove we were exec'd; refusing beats silently nesting
    end
  end
end
