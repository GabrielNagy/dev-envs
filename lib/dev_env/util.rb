# frozen_string_literal: true

module DevEnv
  # Console output, subprocess execution and small pure helpers shared by
  # every class.
  module Util
    module_function

    # A project slug becomes a DNS label and part of its database names, so
    # keep it to the intersection of what both accept.
    MAX_LABEL = 40

    BOLD    = "1"
    MUTED   = "90"
    RED     = "31"
    GREEN   = "32"
    YELLOW  = "33"
    MAGENTA = "35"
    CYAN    = "36"

    def color(message, code, stream: $stdout)
      return message if ENV.key?("NO_COLOR") || !stream.tty?

      "\e[#{code}m#{message}\e[0m"
    end

    def step(message) = puts("#{color('→', CYAN)} #{color(message, BOLD)}")
    def ok(message)   = puts(color("✓ #{message}", GREEN))
    def note(message) = warn(color("! #{message}", YELLOW, stream: $stderr))

    def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def format_duration(seconds)
      return "#{(seconds * 1_000).round}ms" if seconds < 1

      if seconds < 60
        rounded = seconds.round(1)
        return "#{rounded == rounded.to_i ? rounded.to_i : rounded}s"
      end

      total = seconds.round
      hours, remainder = total.divmod(3_600)
      minutes, remaining_seconds = remainder.divmod(60)
      return format("%dh %02dm %02ds", hours, minutes, remaining_seconds) if hours.positive?

      format("%dm %02ds", minutes, remaining_seconds)
    end

    def duration_tag(seconds) = color("[#{format_duration(seconds)}]", MAGENTA)

    def run(*cmd, chdir: nil, env: {}, check: true, quiet: false)
      started_at = monotonic_time
      puts "  #{color("$ #{cmd.join(' ')}", MUTED)}" unless quiet
      options = chdir ? { chdir: chdir } : {}
      success = nil
      begin
        success = system(env, *cmd, **options)
      ensure
        unless quiet
          status = success ? color("done", GREEN) : color("failed", RED)
          puts "  #{color('└─', MUTED)} #{status} #{duration_tag(monotonic_time - started_at)}"
        end
      end
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
