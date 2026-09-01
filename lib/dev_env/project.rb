# frozen_string_literal: true

module DevEnv
  class Project
    include Util

    # "" is the bare hostname; every other key adds a named hostname.
    DEFAULT_SUBDOMAINS = { "" => { "auth" => true }, "app" => { "auth" => true } }.freeze

    def self.load(config)
      here = Util.capture("git", "rev-parse", "--show-toplevel")
      raise Error, "not inside a git repository" if here.empty?

      # Worktrees share a common git dir with the primary checkout; derive the
      # latter from it so running from inside a worktree does not nest new
      # worktrees underneath it.
      common = Util.capture("git", "rev-parse", "--path-format=absolute", "--git-common-dir")
      root = common.empty? ? here : File.dirname(common)

      # Prefer the config in the checkout being used, so a branch can change
      # it before the primary checkout has the change.
      path = [here, root].map { |dir| File.join(dir, ".dev-env.json") }.find { |p| File.exist?(p) }
      settings = path ? JSON.parse(File.read(path)) : config.project_settings(root)
      unless settings
        raise Error, "no project configuration for #{here} — run `dev-env init` or add #{root.inspect} " \
                     "to projects in #{config.path}"
      end
      source = path || "projects[#{root.inspect}] in #{config.path}"
      raise Error, "project configuration in #{source} must be an object" unless settings.is_a?(Hash)

      new(config, root: root, settings: settings)
    end

    attr_reader :root

    def initialize(config, root:, settings:)
      @config = config
      @root = root
      @settings = settings
    end

    def name = @name ||= slugify(@settings["name"] || File.basename(root))

    def commands        = @settings["commands"] || {}
    # Recorded into each environment's state at `up`, so `down` works without
    # reaching the project configuration.
    def database_settings = @settings["database"]
    def database          = @database ||= Database.for(database_settings)
    def process_manager = @settings["process_manager"]
    def after_down      = Array(@settings["after_down"])
    def worktree_files  = @settings["worktree_files"] || {}
    def install_cache   = @settings["install_cache"]

    def seed_template
      return @seed_template if defined?(@seed_template)

      spec = @settings["seed_template"]
      @seed_template = spec && SeedTemplate.new(cache_dir: @config.cache_dir, project_root: root,
                                                default_database: "dev_env_#{name.tr('-', '_')}_template",
                                                spec: spec)
    end

    def summary
      value = @settings["summary"] || {}
      raise Error, "summary in project configuration must be an object" unless value.is_a?(Hash)

      value
    end

    def public?
      value = @settings.fetch("public", false)
      raise Error, "public in project configuration must be true or false" unless [true, false].include?(value)

      value
    end

    def worktree_root = File.join(File.dirname(root), "#{File.basename(root)}-worktrees")

    def key_for(branch, id) = "#{name}--#{slugify(branch)}--#{id}"

    # Directly beneath the base domain, so one wildcard DNS record and
    # certificate cover every project.
    def domain_for(id) = "#{id}-#{name}.#{@config.base_domain}"

    # "dev_env_" plus a 40-character name, a 5-digit port and the 8-character
    # ID stays within PostgreSQL's 63-byte identifier limit, the tighter of
    # the two engines.
    def database_for(port, id) = "dev_env_#{name.tr('-', '_')}_#{port}_#{id.tr('-', '_')}"

    # A bare true or false is shorthand for the auth flag alone, which
    # defaults to true; "" is the bare hostname.
    def subdomains
      @subdomains ||= begin
        raw = @settings["subdomains"] || DEFAULT_SUBDOMAINS
        raise Error, "subdomains in project configuration must be an object" unless raw.is_a?(Hash)
        raise Error, "subdomains in project configuration is empty" if raw.empty?

        raw.map do |label, spec|
          spec = { "auth" => spec } if [true, false].include?(spec)
          spec = {} if spec.nil?
          raise Error, "subdomain #{label.inspect} must be an object or a boolean" unless spec.is_a?(Hash)
          # A wildcard DNS record covers a single level, so a dotted subdomain
          # would need its own record to resolve at all.
          valid = label.empty? || label.match?(/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/)
          raise Error, "#{label.inspect} is not a usable subdomain label" unless valid
          { "label" => label, "auth" => spec.fetch("auth", true) }
        end
      end
    end

    # Folded into the leftmost label (app-pkliinp6-project.example.com) so
    # the machine-wide wildcard certificate covers the subdomain.
    def host_for(domain, label)
      return domain if label.empty?

      first, rest = domain.split(".", 2)
      "#{label}-#{first}.#{rest}"
    end

    def hosts_for(domain, subs = subdomains) = subs.map { |sub| host_for(domain, sub["label"]) }

    # The _RE forms are escaped for templates embedding a hostname in a
    # regex, where bare dots would quietly loosen host checking.
    def domain_vars(domain)
      vars = {
        "DOMAIN" => domain,
        "DOMAIN_RE" => Regexp.escape(domain),
        "TLD_LENGTH" => domain.count(".").to_s,
      }
      subdomains.each do |sub|
        next if sub["label"].empty?
        prefix = sub["label"].tr("-", "_").upcase
        host = host_for(domain, sub["label"])
        vars["#{prefix}_DOMAIN"] = host
        vars["#{prefix}_DOMAIN_RE"] = Regexp.escape(host)
      end
      vars
    end

    def vars_for(state)
      domain_vars(state["domain"]).merge(
        "PORT" => state["port"].to_s, "DATABASE" => state["database"],
        "BRANCH" => state["branch"], "PROJECT" => state["project"], "WORKTREE" => state["worktree"],
        "DATABASE_URL" => database.url(state["database"]),
      )
    end

    # An explicit PATH because systemd user units start with a minimal one. A
    # null in project configuration drops a variable rather than setting it
    # empty — the only way to withhold a default: dotenv skips any variable
    # the environment already defines, so exporting DATABASE_URL would
    # override the per-environment .env files that keep a test database apart
    # from a development one.
    def app_env_for(vars)
      {
        "DATABASE_URL" => vars["DATABASE_URL"],
        "PORT" => vars["PORT"],
        "WORKTREE" => vars["WORKTREE"],
        "PATH" => "#{File.expand_path('~/.local/bin')}:/usr/local/bin:/usr/bin:/bin",
      }.merge(interpolate(@settings["env"] || {}, vars)).compact
    end
  end
end
