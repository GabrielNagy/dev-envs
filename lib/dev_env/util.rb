# frozen_string_literal: true

module DevEnv
  # Console output, subprocess execution and small pure helpers shared by
  # every class.
  module Util
    module_function

    # A key becomes a DNS label, a database name and a systemd instance name,
    # so keep it to the intersection of what all three accept.
    MAX_LABEL = 40

    def step(message) = puts("\e[36m→\e[0m #{message}")
    def ok(message)   = puts("\e[32m✓\e[0m #{message}")
    def note(message) = warn("\e[33m!\e[0m #{message}")

    def run(*cmd, chdir: nil, env: {}, check: true, quiet: false)
      puts "  \e[90m$ #{cmd.join(' ')}\e[0m" unless quiet
      options = chdir ? { chdir: chdir } : {}
      success = system(env, *cmd, **options)
      raise Error, "command failed: #{cmd.join(' ')}" if check && !success
      success
    end

    # Project-supplied commands are arbitrary shell: a single String makes
    # system() invoke the shell rather than exec an argv.
    def sh(command, chdir:, env: {}, check: true) = run(command, chdir: chdir, env: env, check: check)

    def capture(*cmd)
      IO.popen(cmd, err: File::NULL, &:read).to_s.strip
    end

    def slugify(value)
      slug = value.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")[0, MAX_LABEL].sub(/-+\z/, "")
      raise Error, "could not derive a usable name from #{value.inspect}" if slug.empty?
      slug
    end

    def interpolate(value, vars)
      case value
      when String then value.gsub(/\$\{(\w+)\}/) { vars.fetch(Regexp.last_match(1), "") }
      when Array  then value.map { |item| interpolate(item, vars) }
      when Hash   then value.transform_values { |item| interpolate(item, vars) }
      else value
      end
    end
  end
end
