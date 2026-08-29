# frozen_string_literal: true

module DevEnv
  # Per-slot secrets that outlive environments: passwords and public hostname
  # aliases persist across teardown, so saved browser credentials and
  # bookmarked URLs keep working when a slot is reused.
  class Secrets
    def initialize(dir)
      @dir = dir
    end

    def password_for(key)       = persisted(password_path(key)) { SecureRandom.alphanumeric(16) }
    def hostname_alias_for(key) = persisted(alias_path(key)) { SecureRandom.alphanumeric(8).downcase }

    def password?(key) = File.exist?(password_path(key))

    private

    def password_path(key) = File.join(@dir, "#{key}.password")
    def alias_path(key)    = File.join(@dir, "#{key}.hostname-alias")

    def persisted(path)
      FileUtils.mkdir_p(@dir)
      unless File.exist?(path)
        File.write(path, yield)
        File.chmod(0o600, path)
      end
      File.read(path).strip
    end
  end
end
