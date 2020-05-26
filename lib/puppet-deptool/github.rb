require 'fileutils'
require 'pp'

require 'puppet-deptool/base'

module PuppetDeptool
  class Github < Base
    class << self
      def uri(address)
        address = GITHUB_BASE_URL + address unless address =~ %r{^http}
        URI(address)
      end

      def token_file
        @token_file ||= File.join(GLOBAL_DEPTOOL_DIR, 'token')
      end

      def fetch_token
        return @token unless @token.nil?
        if File.exist?(token_file)
          debug "Reading token file #{token_file}"
          token = File.read(token_file).chomp
          res = req('/user', token)
          if res.is_a? Net::HTTPSuccess
            @token = token
            return @token
          end
          warn "Failed to authenticate with existing token: #{res.body}"
        end
        num = 0
        max = 5
        print "github.umn.edu Username: "
        username = gets.chomp
        print "gihub.umn.edu Password: "
        password = STDIN.noecho(&:gets).chomp
        puts ""
        while num < max
          num += 1
          puts "Creating token#{num > 1 ? " (try #{num} of #{max})" : ""}"
          request = Net::HTTP::Post.new(uri '/authorizations')
          request.basic_auth username, password
          request.body = {
            'scopes'   => 'repo',
            'note_url' => 'https://github.umn.edu/MSI-Puppet',
            'note'     => "deptool for #{%x[whoami].chomp}@#{%x[hostname -f].chomp}#{num > 1 ? " #{num}" : ""}"
          }.to_json
          request.content_type = 'application/json'
          debug "Sending request #{request.body}"
          res = req(request)
          json = parse_json(res)
          case res
          when Net::HTTPSuccess
            debug 'Success:'
            token = json['token']
            begin
              FileUtils.mkdir_p(File.dirname(token_file))
              File.open(token_file, 'w') do |file|
                file.write(token)
              end
              return token
            rescue Exception => e
              warn "Failed to write token to #{token_file}: #{e.message}"
              break
            end
          else
            if json['message'] == 'Validation Failed' && \
                json['errors'][0]['code'] == 'already_exists'
              info 'Token already exists. Creating new one'
              next
            elsif json['message'] =~ /Must authenticate/
              warn 'Invalid credentials'
              break
            else
              warn "Unknown failure: #{res.body}"
              break
            end
          end
        end
        warn 'Failed to fetch token'
        exit 1
      end

      def req(address, token = nil)
        if address.is_a? Net::HTTPRequest
          request = address
          u = request.uri
        else
          u = uri(address)
          request = Net::HTTP::Get.new(u)
          request['Authorization'] = "token #{token || fetch_token}"
        end
        debug "Sending request #{request.uri}, headers #{request.to_hash}"
        http = Net::HTTP.new(u.hostname, u.port)
        http.use_ssl = true
        #http.set_debug_output($stderr) if Logger.debug
        res = http.request(request)
        debug "Got response body #{res.body}, headers #{res.to_hash}"
        res
      end

      def parse_json(res)
        begin
          json = JSON.parse(res.body)
        rescue Exception => e
          raise "Failed to parse JSON from response '#{res.body}': #{e.message}"
        end
      end

      def repositories
        res = req('/orgs/MSI-Puppet/repos?per_page=100')
        repos = parse_json(res)
        while url = next_page(res)
          debug "Found next page #{url}"
          res = req(url)
          repos += parse_json(res)
        end
        repos
      end

      def control_repositories
        info "Fetching list of control repos from github"
        control_repos = repositories.select do |repo|
          debug "Checking repository #{repo['name']}"
          if %r{^(?<name>.*)_control$} =~ repo['name']
            debug "Found control repository #{repo['name']}:\n#{repo}"
            repo['environment_prefix'] = name
            true
          end
        end
        info "Found github control repositories #{control_repos.map {|r| r['name']}}"
        control_repos
      end

      def next_page(res)
        link = res['Link'] || ''
        link.scan(%r{<(?<url>[^>]+)>; rel="(?<target>[^"]+)}) do |match|
          return match[0] if match[1] == 'next'
        end
        return nil
      end
    end
  end
end
