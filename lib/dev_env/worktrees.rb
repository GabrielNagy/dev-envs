# frozen_string_literal: true

module DevEnv
  # Git worktree lifecycle and the untracked files each worktree needs.
  class Worktrees
    include Util

    def initialize(project)
      @project = project
    end

    # The path of the worktree this repository already has checked out on
    # `branch`, or nil.
    def existing_for(branch)
      path = nil
      capture("git", "-C", @project.root, "worktree", "list", "--porcelain").each_line do |line|
        line = line.chomp
        path = line.delete_prefix("worktree ") if line.start_with?("worktree ")
        return path if line == "branch refs/heads/#{branch}"
      end
      nil
    end

    # A checkout dev-env did not create is only usable if it really is this
    # repository's, on this branch. Serving someone else's directory would be
    # silently wrong in both directions.
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

    def remove(worktree, quiet: false)
      run("git", "-C", @project.root, "worktree", "remove", "--force", worktree, check: false, quiet: quiet)
    end

    # Untracked files a project needs in every worktree: gitignored secrets it
    # cannot check in, or settings branches predating a change would otherwise
    # lack.
    def write_files(worktree, domain)
      vars = @project.domain_vars(domain).merge("ROOT" => @project.root)

      @project.link_from_root.each do |pattern|
        Dir.glob(File.join(@project.root, pattern)).each do |source|
          target = File.join(worktree, source.delete_prefix(@project.root + "/"))
          # When the adopted worktree is the primary checkout itself, source
          # and target coincide, and ln_sf would replace the real file with a
          # symlink to itself, destroying it.
          next if File.expand_path(target) == File.expand_path(source)

          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.ln_sf(source, target)
        end
      end

      @project.worktree_files.each do |relative, spec|
        spec = { "content" => spec } if spec.is_a?(Array) || spec.is_a?(String)
        guard = spec["unless_file_contains"]
        if guard && File.exist?(File.join(worktree, guard["file"])) &&
           File.read(File.join(worktree, guard["file"])).include?(guard["text"])
          next
        end

        body = Array(spec["content"]).join("\n")
        target = File.join(worktree, relative)
        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, interpolate(body, vars) + "\n")

        # git reads info/exclude from the common git dir, not the per-worktree
        # one, so writing to the latter would be silently ignored.
        git_dir = capture("git", "-C", worktree, "rev-parse", "--path-format=absolute", "--git-common-dir")
        unless git_dir.empty?
          exclude = File.join(git_dir, "info", "exclude")
          FileUtils.mkdir_p(File.dirname(exclude))
          existing = File.exist?(exclude) ? File.read(exclude) : ""
          File.write(exclude, "#{existing.chomp}\n#{relative}\n") unless existing.include?(relative)
        end
        ok "Wrote #{relative} into the worktree"
      end
    end
  end
end
