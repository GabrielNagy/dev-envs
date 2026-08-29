# frozen_string_literal: true

module DevEnv
  # Per-environment secrets. A password lives exactly as long as its
  # environment record: created on `up`, stable across restarts and inactive
  # periods, removed on `down`.
  class Secrets
    def initialize(dir)
      @dir = dir
    end

    def password_for(key) = persisted(password_path(key)) { SecureRandom.alphanumeric(16) }

    def password?(key) = File.exist?(password_path(key))

    def delete_password(key) = FileUtils.rm_f(password_path(key))

    private

    def password_path(key) = File.join(@dir, "#{key}.password")

    # Created atomically with the final 0600 mode, so no reader can see a
    # partially written or world-readable secret.
    def persisted(path)
      FileUtils.mkdir_p(@dir)
      unless File.exist?(path)
        tmp = "#{path}.#{Process.pid}.tmp"
        File.open(tmp, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(yield) }
        File.rename(tmp, path)
      end
      File.read(path).strip
    end
  end
end
