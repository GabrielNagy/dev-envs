# frozen_string_literal: true

module DevEnv
  # Everything derived from the repository dev-env runs in: its .dev-env.json
  # settings, the hostnames each environment answers on, and the variables
  # interpolated into project commands.
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
      raise Error, "no .dev-env.json in #{here} — run: dev-env init" if path.nil?

      new(config, root: root, settings: JSON.parse(File.read(path)))
    end

    attr_reader :root

    def initialize(config, root:, settings:)
      @config = config
      @root = root
      @settings = settings
    end

    def name = @name ||= slugify(@settings["name"] || File.basename(root))

    def commands        = @settings["commands"] || {}
    # Recorded into each environment's state at `up`, so `down` can rebuild
    # the same adapter without reaching the repository's .dev-env.json.
    def database_settings = @settings["database"]
    def database          = @database ||= Database.for(database_settings)
    def process_manager = @settings["process_manager"]
    def after_restore   = Array(@settings["after_restore"])
    def after_down      = Array(@settings["after_down"])
    def link_from_root  = Array(@settings["link_from_root"])
    def worktree_files  = @settings["worktree_files"] || {}

    def public?
      value = @settings.fetch("public", false)
      raise Error, "public in .dev-env.json must be true or false" unless [true, false].include?(value)

      value
    end

    # Worktrees sit in a container folder beside the checkout, never loose in
    # the parent directory.
    def worktree_root
      @settings["worktree_root"] || File.join(File.dirname(root), "#{File.basename(root)}-worktrees")
    end

    # Generated artifacts share a descriptive key while the environment ID
    # remains the concise external selector.
    def key_for(branch, id) = "#{name}--#{slugify(branch)}--#{id}"

    # Keep every environment directly beneath the machine's base domain so
    # one wildcard DNS record and certificate cover every project.
    def domain_for(id) = "#{id}-#{name}.#{@config.base_domain}"

    # "dev_env_" plus a 40-character name, a 5-digit port and the 8-character
    # ID is exactly PostgreSQL's 63-byte identifier limit (MySQL allows 64).
    def database_for(port, id) = "dev_env_#{name.tr('-', '_')}_#{port}_#{id.tr('-', '_')}"

    def default_dump = File.join(@config.dump_dir, @settings["seed"] || "#{name}-seed#{database.dump_extension}")

    # The hostnames one environment answers on. A project declares them as
    # {"": {"auth": true}, "mcp": {"auth": false}}; a bare true or false is
    # shorthand for the auth flag alone, which defaults to true.
    def subdomains
      @subdomains ||= begin
        raw = @settings["subdomains"] || DEFAULT_SUBDOMAINS
        raise Error, "subdomains in .dev-env.json must be an object" unless raw.is_a?(Hash)
        raise Error, "subdomains in .dev-env.json is empty" if raw.empty?

        raw.map do |label, spec|
          spec = { "auth" => spec } if [true, false].include?(spec)
          spec = {} if spec.nil?
          raise Error, "subdomain #{label.inspect} must be an object or a boolean" unless spec.is_a?(Hash)
          # One label only: a wildcard DNS record covers a single level, so a
          # dotted subdomain would need its own record to resolve at all.
          valid = label.empty? || label.match?(/\A[a-z0-9]([a-z0-9-]*[a-z0-9])?\z/)
          raise Error, "#{label.inspect} is not a usable subdomain label" unless valid
          { "label" => label, "auth" => spec.fetch("auth", true) }
        end
      end
    end

    # Subdomain labels are folded into the leftmost label
    # (app-pkliinp6-project.example.com) so the machine-wide wildcard
    # certificate covers them.
    def host_for(domain, label)
      return domain if label.empty?

      first, rest = domain.split(".", 2)
      "#{label}-#{first}.#{rest}"
    end

    def hosts_for(domain, subs = subdomains) = subs.map { |sub| host_for(domain, sub["label"]) }

    # Hostname interpolation vars: ${DOMAIN} for the bare hostname, plus a
    # ${MCP_DOMAIN} and ${MCP_DOMAIN_RE} for each declared subdomain. The _RE
    # forms are escaped for templates embedding a hostname in a regex, where
    # bare dots would quietly loosen host checking.
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

    # Interpolation vars for one environment, derived from its state so `up`
    # and `seed` build them identically.
    def vars_for(state)
      domain_vars(state["domain"]).merge(
        "PORT" => state["port"].to_s, "DATABASE" => state["database"],
        "BRANCH" => state["branch"], "PROJECT" => state["project"], "WORKTREE" => state["worktree"],
        "DATABASE_URL" => database.url(state["database"]),
      )
    end

    # systemd user units start with a minimal PATH, so version managers under
    # ~/.local/bin would not resolve. Carry an explicit one into both the
    # setup commands and the generated environment file.
    def app_env_for(vars)
      {
        "DATABASE_URL" => vars["DATABASE_URL"],
        "PORT" => vars["PORT"],
        "WORKTREE" => vars["WORKTREE"],
        "PATH" => "#{File.expand_path('~/.local/bin')}:/usr/local/bin:/usr/bin:/bin",
      }.merge(interpolate(@settings["env"] || {}, vars))
    end
  end
end
