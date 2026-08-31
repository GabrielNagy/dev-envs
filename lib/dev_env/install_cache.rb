# frozen_string_literal: true

module DevEnv
  # Copies a successfully installed dependency directory into a machine-local
  # snapshot and uses it to seed new worktrees with the same dependency inputs.
  # The project's install command still runs after every restore and remains
  # the authority on whether the resulting installation is valid.
  class InstallCache
    include Util

    VERSION = 1

    attr_reader :directory

    def initialize(cache_dir:, project_root:, worktree:, command:, spec:)
      unless spec.is_a?(Hash)
        raise Error, "install_cache in project configuration must be an object"
      end

      @worktree = File.expand_path(worktree)
      @command = command
      @directory = spec["directory"]
      @key_patterns = spec["key_files"]
      validate_spec!

      @target = inside_worktree(directory, "install_cache.directory")
      project_id = Digest::SHA256.hexdigest(File.expand_path(project_root))
      parent = File.join(cache_dir, "installs")
      @snapshot = File.join(parent, project_id)
      @lock_path = File.join(parent, "#{project_id}.lock")
    end

    def restore
      return false if File.exist?(@target) || File.symlink?(@target)

      with_lock do
        return false unless snapshot_matches?

        started_at = monotonic_time
        step "Restoring cached #{directory}"
        FileUtils.cp_r(snapshot_directory, @target, preserve: true)
        ok "Restored #{directory} #{duration_tag(monotonic_time - started_at)}"
        true
      rescue SystemCallError => error
        FileUtils.rm_rf(@target)
        FileUtils.rm_rf(@snapshot)
        note "Could not restore cached #{directory} (#{error.message}); installing from scratch"
        false
      end
    end

    def store
      return false unless File.exist?(@target) || File.symlink?(@target)
      if File.symlink?(@target) || !File.directory?(@target)
        raise Error, "install_cache.directory must be a directory, not #{@target}"
      end

      with_lock do
        return false if snapshot_matches?

        started_at = monotonic_time
        step "Saving #{directory} to the install cache"
        replace_snapshot
        ok "Cached #{directory} #{duration_tag(monotonic_time - started_at)}"
        true
      end
    rescue SystemCallError => error
      note "Could not cache #{directory} (#{error.message}); continuing without updating the install cache"
      false
    end

    private

    def validate_spec!
      inside_worktree(directory, "install_cache.directory")
      unless @key_patterns.is_a?(Array) && !@key_patterns.empty? && @key_patterns.all? { |item| item.is_a?(String) }
        raise Error, "install_cache.key_files in project configuration must be a non-empty array of paths or globs"
      end
      @key_patterns.each { |pattern| validate_relative(pattern, "install_cache.key_files") }
    end

    def inside_worktree(path, setting)
      validate_relative(path, setting)
      expanded = File.expand_path(path, @worktree)
      prefix = "#{@worktree}#{File::SEPARATOR}"
      raise Error, "#{setting} must stay inside the worktree" unless expanded.start_with?(prefix)

      expanded
    end

    def validate_relative(path, setting)
      invalid = !path.is_a?(String) || path.empty? || Pathname.new(path).absolute? || path.split(File::SEPARATOR).include?("..")
      raise Error, "#{setting} must contain relative paths inside the worktree" if invalid
    end

    def fingerprint
      digest = Digest::SHA256.new
      digest << "dev-env-install-cache-v#{VERSION}\0#{directory}\0#{@command}\0"
      @key_patterns.sort.each do |pattern|
        digest << "pattern\0#{pattern}\0"
        paths = Dir.glob(File.join(@worktree, pattern), File::FNM_DOTMATCH).select { |path| File.file?(path) }.sort
        digest << "missing\0" if paths.empty?
        paths.each do |path|
          relative = path.delete_prefix("#{@worktree}#{File::SEPARATOR}")
          digest << "file\0#{relative}\0"
          File.open(path, "rb") do |file|
            while (chunk = file.read(1024 * 1024))
              digest << chunk
            end
          end
          digest << "\0"
        end
      end
      digest.hexdigest
    end

    def snapshot_directory = File.join(@snapshot, "directory")
    def snapshot_fingerprint = File.join(@snapshot, "fingerprint")

    def snapshot_matches?
      File.directory?(snapshot_directory) && File.file?(snapshot_fingerprint) &&
        File.read(snapshot_fingerprint).strip == fingerprint
    end

    def with_lock
      FileUtils.mkdir_p(File.dirname(@lock_path))
      File.open(@lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        yield
      end
    end

    def replace_snapshot
      parent = File.dirname(@snapshot)
      temporary = Dir.mktmpdir(".install-cache-", parent)
      previous = "#{@snapshot}.previous.#{Process.pid}.#{SecureRandom.hex(6)}"
      FileUtils.cp_r(@target, File.join(temporary, "directory"), preserve: true)
      File.write(File.join(temporary, "fingerprint"), "#{fingerprint}\n")

      File.rename(@snapshot, previous) if File.exist?(@snapshot)
      begin
        File.rename(temporary, @snapshot)
      rescue StandardError
        File.rename(previous, @snapshot) if File.exist?(previous) && !File.exist?(@snapshot)
        raise
      end
      FileUtils.rm_rf(previous)
    ensure
      FileUtils.rm_rf(temporary) if temporary && File.exist?(temporary)
    end
  end
end
