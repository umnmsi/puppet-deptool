require 'open3'

module PuppetDeptool
  module Git
    @@update_cache = {}

    def git(args, opts = {})
      argv = ['git']
      if opts[:path]
        argv << '--git-dir' << File.join(opts[:path], '.git')
        argv << '--work-tree' << opts[:path]
      end
      argv.concat(args)
      cmd = argv.join(' ')
      debug "Running `#{cmd}`"
      out, err, status = Open3.capture3(cmd)
      info err unless err.empty?
      debug out unless out.empty?
      raise GitError, "git command `#{cmd}` exited with non-zero status #{status.exitstatus}" unless status.success?
      out
    end

    def current_branch(opts = {})
      git(['rev-parse', '--abbrev-ref', 'HEAD'], opts).chomp
    end

    def current_commit(opts = {})
      git(['rev-parse', 'HEAD'], opts).chomp
    end

    def remote_branches(opts = {})
      opts[:remote] ||= 'origin'
      git(['for-each-ref', '--format', '"%(refname:short)"', "refs/remotes/#{opts[:remote]}"], opts).each_line.map do |ref|
        ref.gsub(%r{"},'').chomp
      end
    end

    def branch_exists?(branch, opts = {})
      remote_branches(opts).any? do |rb|
        debug "Comparing remote branch #{rb} to #{branch}"
        rb.match?(%r{^(.+/)?#{branch}$})
      end
    end

    def ref_to_branch(ref)
      ref.sub(%r{^.+/},'')
    end

    # expects repo hash { 'name' => <name>, 'ssh_url' => <ssh_url> }
    def clone_or_update(repo)
      cache_dir = File.join(PuppetDeptool::DEPTOOL_CACHE, repo['name'])
      return cache_dir if @@update_cache.key? cache_dir
      if File.directory? cache_dir
        info "Fetching updates for #{repo['name']} in #{cache_dir}"
        @current_path = cache_dir
        git ['fetch', '--prune'], path: cache_dir
      else
        info "Cloning #{repo['name']} into #{cache_dir}"
        FileUtils.mkdir_p(PuppetDeptool::DEPTOOL_CACHE)
        git ['clone', repo['ssh_url'], cache_dir]
      end
      @@update_cache[cache_dir] = cache_dir
    end

    def checkout(ref, opts)
      info "Checking out #{ref}#{opts[:clean] ? ' and cleaning' : ''}"
      args = ['checkout', ref]
      args << '--force' if opts.delete(:force) == true
      git(args, opts)
      git(['clean', '-ffdx'], opts) if opts[:clean]
    end

    class GitError < StandardError; end
  end
end
