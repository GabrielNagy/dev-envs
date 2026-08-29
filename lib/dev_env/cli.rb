# frozen_string_literal: true

module DevEnv
  # Command-line entry point: parses options, wires the collaborators together
  # and owns the per-command workflows.
  class CLI
    include Util

    COMMANDS = %w[setup init up down list creds logs restart exec activate seed warm].freeze

    USAGE = <<~TEXT
      Usage: dev-env <command> [options]

      Per machine:
        setup             Detect the public address, write the Caddy config and unit
      Per project (run inside its repository):
        init              Write a starter .dev-env.json
        up <branch>       Claim a free slot: worktree, database and service
        down <slot>       Tear an environment down and free its slot
        list              Show every environment, and this project's free slots
        creds [slot]      Show the basic-auth credentials
        logs [slot] [-f]  Follow the log
        restart [slot]    Restart the service
        exec [slot] -c "command"
                          Run a command in the environment's worktree and env
        activate [slot]   Open a shell in the environment's worktree and env; exit to leave
        seed [slot]       Rebuild the database from the seed dump
        warm              Rewrite every slot's Caddy site and pre-issue certificates

      Run from inside an environment's worktree, commands taking [slot] default
      to that environment when the slot is omitted.

      Environments occupy a fixed per-project pool, served at
      per-slot HTTPS hostnames, with the subdomains and which of them sit behind
      basic auth declared in .dev-env.json
    TEXT

    def initialize(config: Config.new)
      @config = config
    end

    def start(argv)
      command = argv.shift
      if command.nil? || %w[-h --help help].include?(command)
        puts USAGE
      elsif COMMANDS.include?(command)
        if @config.exist? && %w[setup up down creds seed warm].include?(command)
          Caddy.new(@config).ensure_certificate_configuration!
        end
        send("cmd_#{command}", argv)
      else
        warn "Unknown command: #{command}\n\n#{USAGE}"
        exit 1
      end
    rescue Error => error
      warn "\e[31m✗\e[0m #{error.message}"
      exit 1
    end

    # ------------------------------------------------------------------ setup

    def cmd_setup(_argv)
      ip = capture("sh", "-c", "ip -4 route get 1.1.1.1 2>/dev/null | grep -oP 'src \\K[0-9.]+'")
      raise Error, "could not detect a public IPv4 address" if ip.empty?
      FileUtils.mkdir_p([@config.home, @config.state_dir, @config.dump_dir, @config.run_dir, @config.secret_dir])
      FileUtils.chmod(0o700, @config.secret_dir)

      unless @config.exist?
        File.write(@config.path, JSON.pretty_generate({
          "base_domain" => "example.com",
          "bind_ip" => ip,
          "port_range" => [4000, 4999],
          "pool_size" => 3,
          "acme_email" => "",
          "acme_dns_provider" => "",
        }) + "\n")
        ok "Wrote #{@config.path} — set base_domain and acme_email, then re-run setup. " \
           "Set acme_dns_provider (e.g. \"route53\") too if projects should get a " \
           "wildcard certificate instead of one certificate per hostname."
        return
      end

      if @config["bind_ip"] != ip
        note "config bind_ip is #{@config['bind_ip'].inspect} but this box answers on #{ip}"
      end

      step "Writing #{@config.caddyfile} (needs sudo)"
      IO.popen(["sudo", "tee", @config.caddyfile], "w") { |io| io.write(Caddy.new(@config).caddyfile_content) }
      run("sudo", "mkdir", "-p", @config.sites_dir)
      run("sudo", "chown", "#{ENV['USER']}:caddy", @config.sites_dir)
      run("sudo", "chmod", "2775", @config.sites_dir)
      run("sudo", "systemctl", "restart", "caddy")

      systemd.install
      ok "Ready. Add .dev-env.json to a project with: dev-env init"
    end

    def cmd_init(_argv)
      root = capture("git", "rev-parse", "--show-toplevel")
      raise Error, "not inside a git repository" if root.empty?
      path = File.join(root, ".dev-env.json")
      raise Error, "#{path} already exists" if File.exist?(path)

      File.write(path, JSON.pretty_generate({
        "name" => File.basename(root),
        "commands" => {
          "install" => "bundle check || bundle install --jobs 4",
          "schema"  => "bin/rails db:schema:load",
          "migrate" => "bin/rails db:migrate",
          "server"  => "bin/rails server -b 127.0.0.1 -p ${PORT}",
        },
        "env" => { "RAILS_ENV" => "development" },
        "subdomains" => { "" => { "auth" => true }, "app" => { "auth" => true } },
        "after_restore" => [],
        "worktree_files" => {},
      }) + "\n")
      ok "Wrote #{path} — edit it to match this project, then: dev-env up <branch>"
    end

    # --------------------------------------------------------------------- up

    def cmd_up(argv)
      options = { basic_auth: true, base: "origin/main" }
      parser = OptionParser.new do |o|
        o.banner = "Usage: dev-env up <branch> [options]"
        o.on("--slot SLOT", "Pool slot to use (#{project.pool.join(', ')}); default: first free") { |v| options[:slot] = v }
        o.on("--seed PATH", "Dump to restore (default: #{project.default_dump})") { |v| options[:seed] = v; options[:seed_given] = true }
        o.on("--no-seed", "Skip the dump; build the schema from migrations") { options[:no_seed] = true }
        o.on("--public", "Serve on a randomized hostname without HTTP basic auth") { options[:basic_auth] = false }
        o.on("--base REF", "Base ref when the branch does not exist (default: origin/main)") { |v| options[:base] = v }
        o.on("--worktree PATH", "Serve an existing checkout instead of creating one") { |v| options[:worktree_path] = v }
      end
      parser.parse!(argv)
      branch = argv.shift
      raise Error, parser.banner if branch.nil?

      slot = allocate_slot(options[:slot])
      key = project.key_for(slot)
      database = project.database_for(key)
      # git allows a branch in only one worktree, so a checkout that already exists is the one to
      # serve, not a conflict to refuse. An agent's worktree is the common case.
      worktree = File.expand_path(options[:worktree_path] || worktrees.existing_for(branch) ||
                                  File.join(project.worktree_root, slugify(branch)))
      worktrees.verify_adopted!(worktree, branch) if Dir.exist?(worktree)
      seed = options[:no_seed] ? nil : (options[:seed] || project.default_dump)

      state = {
        "key" => key, "slot" => slot, "project" => project.name, "branch" => branch,
        "domain" => project.domain_for(options[:basic_auth] ? slot : secrets.hostname_alias_for(key)),
        "port" => @config.free_port(reserved: store.keys.map { |k| store.load(k)["port"] }),
        "database" => database, "worktree" => worktree,
        # Only a worktree this command created may be torn down by it, on rollback or on `down`.
        "worktree_owned" => !Dir.exist?(worktree),
        "basic_auth" => options[:basic_auth] && project.subdomains.any? { |sub| sub["auth"] },
        "created_at" => Time.now.utc.iso8601,
      }

      FileUtils.mkdir_p([@config.state_dir, @config.run_dir, project.worktree_root])
      systemd.install unless systemd.installed?

      # A half-built environment is worse than none: undo whatever was created
      # if a later step fails, so the slot is free to retry.
      rollback = []
      begin
        if state["worktree_owned"]
          step "Creating worktree #{worktree} for #{branch}"
          worktrees.create(worktree, branch, options[:base])
          rollback << -> { worktrees.remove(worktree, quiet: true) }
        else
          step "Using existing worktree #{worktree} for #{branch}"
        end
        worktrees.write_files(worktree, state["domain"])

        step "Creating database #{database}"
        if capture("psql", "-tAc", "SELECT 1 FROM pg_database WHERE datname = '#{database}'") == "1"
          raise Error, "database #{database} already exists"
        end
        run("createdb", database)
        rollback << -> { run("dropdb", "--if-exists", database, check: false, quiet: true) }

        build_environment(state, seed, options)
      rescue StandardError => error
        note "Failed partway through — rolling back"
        rollback.reverse_each { |undo| undo.call rescue nil }
        store.delete(key)
        caddy.delete_site(key)
        raise error
      end
    end

    # ------------------------------------------------------------- lifecycle

    def cmd_down(argv)
      options = { worktree: true, database: true }
      parser = OptionParser.new do |o|
        o.banner = "Usage: dev-env down <slot> [options]"
        o.on("--keep-worktree", "Leave the git worktree in place") { options[:worktree] = false }
        o.on("--remove-worktree", "Remove a worktree whose origin predates ownership tracking") { options[:force_worktree] = true }
        o.on("--keep-database", "Leave the postgres database in place") { options[:database] = false }
      end
      parser.parse!(argv)
      raise Error, parser.banner if argv.empty?
      key = resolve(argv.shift)
      state = store.load(key)

      step "Stopping #{systemd.unit(key)}"
      systemd.systemctl("disable", "--now", systemd.unit(key), check: false)

      step "Parking Caddy site"
      # A placeholder rather than a deletion, so Caddy keeps renewing this
      # slot's certificates and the next `up` needs no fresh issuance.
      caddy.write_parking_site(key, state["slot"], state["domain"])
      caddy.reload

      if options[:database]
        step "Dropping database #{state['database']}"
        run("dropdb", "--if-exists", state["database"], check: false)
      end

      # `remove --force` discards uncommitted work and cannot be undone, so removal requires positive
      # evidence that dev-env created this worktree. Three states, not two:
      #   true  — dev-env created it; remove it.
      #   false — adopted from elsewhere; never remove it, and no flag overrides that.
      #   nil   — written before ownership was recorded, so unknown. Older `up` silently adopted a
      #           worktree that already sat at the default path, which is exactly where agents put
      #           theirs, so "unknown" cannot be treated as "ours". Left alone unless forced.
      owned = state["worktree_owned"]
      if !options[:worktree]
        note "Leaving worktree #{state['worktree']} (--keep-worktree)" if owned
      elsif owned == true || (owned.nil? && options[:force_worktree])
        step "Removing worktree #{state['worktree']}"
        worktrees.remove(state["worktree"])
      elsif owned == false
        note "Leaving worktree #{state['worktree']} — dev-env did not create it"
      else
        note "Leaving worktree #{state['worktree']} — predates ownership tracking, so it may be " \
             "an adopted checkout. Remove it yourself, or re-run with --remove-worktree."
      end

      store.delete(key)
      ok "#{state['project']}/#{state['slot']} removed (password kept for reuse)"
    end

    def cmd_list(_argv)
      keys = store.keys
      return puts("No environments.") if keys.empty?

      rows = keys.map do |key|
        state = store.load(key)
        [state["project"].to_s, state["slot"].to_s, state["branch"].to_s,
         state["port"].to_s, systemd.status(key), "https://#{state['domain']}"]
      end
      headers = %w[PROJECT SLOT BRANCH PORT STATUS URL]
      widths = headers.each_with_index.map { |h, i| ([h] + rows.map { |r| r[i] }).map(&:length).max }

      puts headers.each_with_index.map { |h, i| h.ljust(widths[i]) }.join("  ")
      rows.each do |row|
        cells = row.each_with_index.map { |c, i| c.ljust(widths[i]) }
        cells[4] = "#{row[4] == 'active' ? "\e[32m" : "\e[31m"}#{cells[4]}\e[0m"
        puts cells.join("  ")
      end

      free = project.pool.reject { |slot| keys.include?(project.key_for(slot)) }
      puts "\nFree #{project.name} slots: #{free.empty? ? '(none)' : free.join(', ')}"
    rescue Error
      # `list` is useful outside a project directory too; the summary line is not.
    end

    def cmd_creds(argv)
      guarded = project.subdomains.select { |sub| sub["auth"] }
      return puts("No hostname for #{project.name} is behind basic auth.") if guarded.empty?

      key = argv.empty? ? implicit_key : project.key_for(argv.shift)
      if key.nil?
        project.pool.each do |slot|
          slot_key = project.key_for(slot)
          next unless secrets.password?(slot_key)
          status = store.exist?(slot_key) ? "" : "  \e[90m(slot free)\e[0m"
          domain = store.exist?(slot_key) ? store.load(slot_key)["domain"] : project.domain_for(slot)
          host = project.host_for(domain, guarded.first["label"])
          puts "#{slot}  https://#{host}  #{@config.basic_auth_user} / #{secrets.password_for(slot_key)}#{status}"
        end
        return
      end

      domain = store.load(key)["domain"]
      guarded.each_with_index do |sub, index|
        puts "#{index.zero? ? 'URLs' : ''.ljust(4)}     https://#{project.host_for(domain, sub['label'])}"
      end
      puts "Username #{@config.basic_auth_user}"
      puts "Password #{secrets.password_for(key)}"
    end

    def cmd_logs(argv)
      key = resolve_target(argv, "Usage: dev-env logs [slot] [-f]")
      exec("journalctl", "--user", "-u", systemd.unit(key), *argv)
    end

    def cmd_restart(argv)
      key = resolve_target(argv, "Usage: dev-env restart [slot]")
      systemd.systemctl("restart", systemd.unit(key))
      ok(wait_for_boot(store.load(key)["port"]) ? "Restarted #{key}" : "Restarted #{key}, not answering yet")
    end

    def cmd_exec(argv)
      command = nil
      parser = OptionParser.new do |o|
        o.banner = "Usage: dev-env exec [slot] -c \"command\""
        o.on("-c COMMAND", "Command to run in the environment") { |v| command = v }
      end
      parser.parse!(argv)
      raise Error, parser.banner if command.nil?
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
      key = resolve_target(argv, "Usage: dev-env activate [slot]")
      if nested_in_active_shell?
        # A child process cannot make its parent shell exit, so a shell
        # started here could only nest inside the active one. Refuse instead.
        raise Error, "already inside #{ENV['DEV_ENV_ACTIVE']} — `exit` first, or switch shells " \
                     "in place with `exec dev-env activate #{key}`"
      end
      state = store.load(key)
      env = store.saved_env(key).except("PATH").merge("DEV_ENV_ACTIVE" => key)
      ok "Entering #{key} (#{state['worktree']}) — exit to leave"
      $stdout.flush # exec replaces the process before Ruby flushes buffered output
      exec(env, ENV.fetch("SHELL", "/bin/sh"), chdir: state["worktree"])
    end

    def cmd_seed(argv)
      options = {}
      parser = OptionParser.new do |o|
        o.banner = "Usage: dev-env seed [slot] [--seed PATH]"
        o.on("--seed PATH", "Dump to restore (default: #{project.default_dump})") { |v| options[:seed] = v }
      end
      parser.parse!(argv)
      key = resolve_target(argv, parser.banner)
      state = store.load(key)
      dump = options[:seed] || project.default_dump
      raise Error, "seed dump not found: #{dump}" unless File.exist?(dump)

      vars = project.vars_for(state)
      app_env = project.app_env_for(vars)

      step "Stopping #{systemd.unit(key)} while the database is rebuilt"
      systemd.systemctl("stop", systemd.unit(key), check: false)

      step "Recreating #{state['database']}"
      run("dropdb", "--if-exists", state["database"])
      run("createdb", state["database"])
      restore_dump(state["database"], dump, state["worktree"], app_env, vars)

      project_command(interpolate(project.commands, vars)["migrate"], "Running migrations", state["worktree"], app_env)

      systemd.systemctl("start", systemd.unit(key))
      ok(wait_for_boot(state["port"]) ? "Reseeded #{key}" : "Reseeded #{key}, not answering yet")
    end

    def cmd_warm(_argv)
      caddy.ensure_wildcard_site
      # Every slot's site file is rewritten, not just the free ones': a
      # subdomain added to .dev-env.json after an environment came up would
      # otherwise go unserved until that slot's next `up`.
      project.pool.each do |slot|
        key = project.key_for(slot)
        unless store.exist?(key)
          caddy.write_parking_site(key, slot)
          next
        end
        state = store.load(key)
        caddy.write_site(key, state["domain"], state["port"], state["basic_auth"] ? secrets.password_for(key) : nil)
      end
      caddy.reload

      # Certificates are fetched lazily on first request, and the request that
      # triggers issuance fails its own handshake, so retry until one succeeds.
      failed = []
      project.pool.each do |slot|
        key = project.key_for(slot)
        domain = store.exist?(key) ? store.load(key)["domain"] : project.domain_for(slot)
        project.hosts_for(domain).each do |host|
          code = nil
          3.times do
            code = capture("curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "--max-time", "45", "https://#{host}")
            break unless code.to_i.zero?
            sleep 3
          end
          failed << host if code.to_i.zero?
          puts(code.to_i.zero? ? "  \e[31m✗\e[0m #{host}" : "  \e[32m✓\e[0m #{host} (#{code})")
        end
      end

      raise Error, "could not obtain certificates for: #{failed.join(', ')}" if failed.any?
      ok "Certificates warmed for #{project.name}"
    end

    private

    def project  = @project  ||= Project.load(@config)
    def store    = @store    ||= Store.new(state_dir: @config.state_dir, run_dir: @config.run_dir)
    def secrets  = @secrets  ||= Secrets.new(@config.secret_dir)
    def caddy    = @caddy    ||= Caddy.new(@config, project: project)
    def worktrees = @worktrees ||= Worktrees.new(project)
    def systemd   = @systemd   ||= Systemd.new(unit_path: @config.unit_path, env_dir: @config.state_dir, run_dir: @config.run_dir)

    # A fixed pool bounds certificate issuance: each slot's hostnames are
    # issued once and thereafter only renewed, and renewals do not count
    # against Let's Encrypt's weekly limit for new certificates.
    def allocate_slot(requested)
      if requested
        raise Error, "#{requested.inspect} is not a pool slot (#{project.pool.join(', ')})" unless project.pool.include?(requested)
        if store.exist?(project.key_for(requested))
          raise Error, "slot #{requested} is in use by #{store.load(project.key_for(requested))['branch']}"
        end
        return requested
      end

      free = project.pool.find { |slot| !store.exist?(project.key_for(slot)) }
      return free if free

      in_use = project.pool.map { |slot| "  #{slot} → #{store.load(project.key_for(slot))['branch']}" }.join("\n")
      raise Error, "all #{project.pool.length} slots for #{project.name} are in use:\n#{in_use}\n\n" \
                   "Free one with: dev-env down <slot>"
    end

    def build_environment(state, seed, options)
      key, slot, worktree, domain, port, database =
        state.values_at("key", "slot", "worktree", "domain", "port", "database")
      vars = project.vars_for(state)
      app_env = project.app_env_for(vars)
      commands = interpolate(project.commands, vars)

      project_command(commands["install"], "Installing dependencies", worktree, app_env)

      if seed && !File.exist?(seed)
        raise Error, "seed dump not found: #{seed}" if options[:seed_given]
        note "No seed dump at #{seed} — starting with an empty database"
        seed = nil
      end

      if seed
        restore_dump(database, seed, worktree, app_env, vars)
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
      caddy.ensure_wildcard_site
      caddy.write_site(key, domain, port, password)
      store.save(key, state)

      step "Reloading Caddy"
      caddy.reload

      step "Starting #{systemd.unit(key)}"
      systemd.systemctl("enable", "--now", systemd.unit(key))

      note "Not answering on 127.0.0.1:#{port} yet — check: dev-env logs #{slot} -f" unless wait_for_boot(port)
      ok "#{project.name}/#{slot} is up"
      print_summary(key)
    end

    def restore_dump(database, dump, worktree, app_env, vars)
      step "Restoring #{dump} into #{database}"
      run("pg_restore", "--no-owner", "--no-acl", "-d", database, dump, check: false)

      project.after_restore.each { |command| sh(interpolate(command, vars), chdir: worktree, env: app_env) }
    end

    # Steps of `up` and `seed` defined by the project; each is optional.
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

    def print_summary(key)
      state = store.load(key)
      puts
      project.subdomains.each_with_index do |sub, index|
        label = index.zero? ? "URLs" : ""
        open = state["basic_auth"] && !sub["auth"] ? "  \e[33m(no auth)\e[0m" : ""
        puts "  #{label.ljust(10)} https://#{project.host_for(state['domain'], sub['label'])}#{open}"
      end
      puts(state["basic_auth"] ? "  Basic auth #{@config.basic_auth_user} / #{secrets.password_for(key)}" : "  Basic auth \e[33mdisabled\e[0m")
      puts "  Worktree   #{state['worktree']}#{state['worktree_owned'] ? '' : ' (adopted; kept on down)'}"
      puts "  Database   #{state['database']}  (port #{state['port']})"
      puts
      puts "  Logs       dev-env logs #{state['slot']} -f"
      puts "  Tear down  dev-env down #{state['slot']}"
      puts
    end

    def resolve(slot_or_key)
      return slot_or_key if store.exist?(slot_or_key)
      key = project.key_for(slot_or_key)
      return key if store.exist?(key)
      raise Error, "no environment #{slot_or_key.inspect} for #{project.name} (try: dev-env list)"
    end

    # The environment whose worktree contains the current directory, so a
    # command run from inside a served checkout can leave the slot off. A
    # shell entered with `dev-env activate` counts too, even after cd'ing
    # elsewhere.
    def implicit_key
      here = File.realpath(Dir.pwd)
      match = store.keys.filter_map do |key|
        worktree = store.load(key)["worktree"].to_s
        next if worktree.empty? || !Dir.exist?(worktree)
        root = File.realpath(worktree)
        [key, root] if here == root || here.start_with?(root + File::SEPARATOR)
      end.max_by { |_, root| root.length }
      return match.first if match
      active = ENV["DEV_ENV_ACTIVE"].to_s
      active unless active.empty? || !store.exist?(active)
    end

    # The explicit slot argument when given, otherwise the environment
    # inferred from the current directory. Option-like arguments (`logs -f`)
    # are left alone.
    def resolve_target(argv, usage)
      return resolve(argv.shift) if argv.first && !argv.first.start_with?("-")
      implicit_key || raise(Error, "#{usage}\n  no slot given, and #{Dir.pwd} is not inside an environment's worktree")
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
