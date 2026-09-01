# frozen_string_literal: true

module DevEnv
  class Worktrees
    include Util

    def initialize(project)
      @project = project
    end

    def existing_for(branch)
      path = nil
      capture("git", "-C", @project.root, "worktree", "list", "--porcelain").each_line do |line|
        line = line.chomp
        path = line.delete_prefix("worktree ") if line.start_with?("worktree ")
        return path if line == "branch refs/heads/#{branch}"
      end
      nil
    end

    # Serving someone else's directory would be silently wrong in both
    # directions, so an adopted checkout must be this repository's, on this
    # branch.
    def verify_adopted!(worktree, branch)
      common = capture("git", "-C", worktree, "rev-parse", "--path-format=absolute", "--git-common-dir")
      raise Error, "#{worktree} is not a git worktree" if common.empty?
      unless File.dirname(common) == @project.root
        raise Error, "#{worktree} belongs to #{File.dirname(common)}, not #{@project.root}"
      end
      head = capture("git", "-C", worktree, "rev-parse", "--abbrev-ref", "HEAD")
      return if head == branch
      raise Error, "#{worktree} is on #{head.inspect}, not #{branch.inspect}"
    end

    def create(worktree, branch, base)
      root = @project.root
      if capture("git", "-C", root, "worktree", "list", "--porcelain").include?("branch refs/heads/#{branch}\n")
        raise Error, "branch #{branch.inspect} is already checked out in another worktree"
      end

      if system("git", "-C", root, "show-ref", "--verify", "--quiet", "refs/heads/#{branch}")
        run("git", "-C", root, "worktree", "add", worktree, branch)
      elsif system("git", "-C", root, "show-ref", "--verify", "--quiet", "refs/remotes/origin/#{branch}")
        run("git", "-C", root, "worktree", "add", "--track", "-b", branch, worktree, "origin/#{branch}")
      else
        step "Branch #{branch} does not exist; creating it from #{base}"
        run("git", "-C", root, "worktree", "add", "-b", branch, worktree, base)
      end
    end

    def self.dirty?(worktree)
      return false unless Dir.exist?(worktree)

      output, status = Open3.capture2e("git", "-C", worktree, "status", "--porcelain", "--untracked-files=all")
      raise Error, "could not inspect worktree #{worktree}: #{output.strip}" unless status.success?

      !output.empty?
    end

    def self.remove(worktree, root:, force: false, quiet: false)
      return true unless Dir.exist?(worktree)

      command = ["git", "-C", root, "worktree", "remove"]
      command << "--force" if force
      Util.run(*command, worktree, quiet: quiet)
    end

    def remove(worktree, force: false, quiet: false) =
      self.class.remove(worktree, root: @project.root, force: force, quiet: quiet)

    def write_files(worktree, vars)
      @project.worktree_files.each do |relative, content|
        body = Array(content).join("\n")
        target = File.join(worktree, relative)
        FileUtils.mkdir_p(File.dirname(target))
        atomic_write(target, interpolate(body, vars) + "\n")

        # git reads info/exclude from the common git dir, not the per-worktree
        # one, so writing to the latter would be silently ignored.
        git_dir = capture("git", "-C", worktree, "rev-parse", "--path-format=absolute", "--git-common-dir")
        unless git_dir.empty?
          exclude = File.join(git_dir, "info", "exclude")
          FileUtils.mkdir_p(File.dirname(exclude))
          existing = File.exist?(exclude) ? File.read(exclude) : ""
          atomic_write(exclude, "#{existing.chomp}\n#{relative}\n") unless existing.include?(relative)
        end
        ok "Wrote #{relative} into the worktree"
      end
    end
  end
end
