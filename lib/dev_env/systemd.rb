# frozen_string_literal: true

module DevEnv
  # The systemd user unit template and per-unit control.
  class Systemd
    include Util

    def initialize(unit_path:, env_dir:, run_dir:)
      @unit_path = unit_path
      @env_dir = env_dir
      @run_dir = run_dir
    end

    def unit(key) = "dev-env@#{key}.service"

    def systemctl(*args, check: true) = run("systemctl", "--user", *args, check: check, quiet: true)

    def status(key) = capture("systemctl", "--user", "is-active", unit(key))

    def installed? = File.exist?(@unit_path)

    def configure_process_manager(key, manager) = configure_overmind(key, enabled: manager == "overmind")

    def install
      FileUtils.mkdir_p(File.dirname(@unit_path))
      File.write(@unit_path, <<~UNIT)
        [Unit]
        Description=dev-env %i
        After=network-online.target

        [Service]
        Type=simple
        EnvironmentFile=#{@env_dir}/%i.env
        ExecStart=#{@run_dir}/%i.sh

        Restart=on-failure
        RestartSec=3
        TimeoutStopSec=15
        KillSignal=SIGTERM

        StandardOutput=journal
        StandardError=journal
        SyslogIdentifier=dev-env-%i

        [Install]
        WantedBy=default.target
      UNIT
      systemctl("daemon-reload")
    end

    private

    def configure_overmind(key, enabled:)
      path = File.join(File.dirname(@unit_path), "#{unit(key)}.d", "dev-env-overmind.conf")
      if enabled
        content = <<~UNIT
          [Service]
          KillMode=mixed
          ExecStopPost=-/bin/sh -c 'rm -f "$WORKTREE/.overmind.sock"'
        UNIT
        return if File.exist?(path) && File.read(path) == content

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      else
        return unless File.exist?(path)

        FileUtils.rm_f(path)
        directory = File.dirname(path)
        Dir.rmdir(directory) if Dir.empty?(directory)
      end
      systemctl("daemon-reload")
    end
  end
end
