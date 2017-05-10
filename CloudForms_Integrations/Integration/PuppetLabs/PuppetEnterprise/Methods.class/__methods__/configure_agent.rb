#
# Description:   Configures the Puppet Agent for registration with Puppet Master
# Author:        Dustin Scott, Red Hat
# Creation Date: 5-Jan-2017
# Requirements:
#   - Network connectivity present
#   - Port 22 open between CloudForms Worker/Client
#   - System was properly registered to Satellite and has access to custom repo with $puppet_agent_pkg package
#   - Username/Passwordd store in /DoS_Variables/Common/OperatingSystems/Linux
#

# ====================================
# set global method variables
# ====================================

# set method variables
@method = $evm.current_method
@org    = $evm.root['tenant'].name
@debug  = $evm.root['debug'] || false

# set method constants
SSH_INSTANCE_PATH = '/Common/SSH/RunSshCommand'

# ====================================
# define methods
# ====================================

# define log method
def log(level, msg)
  $evm.log(level,"#{@org} Automation: #{msg}")
end

# method for calling ssh
def run_ssh(host, shell_command, ssh_timeout = 60, valid_exit_code = 0)
  begin
    # define basic query
    ssh_query = {
      :ssh_host            => host,
      :ssh_auth_type       => :password,     # password is set on ssh method (default per os during provisioning)
      :ssh_timeout         => ssh_timeout,
      :ssh_debug           => @debug,
      :ssh_command         => shell_command,
      :ssh_valid_exit_code => valid_exit_code
    }

    # instantiate the ssh method and pull the command status
    $evm.instantiate(SSH_INSTANCE_PATH + '?' + ssh_query.to_query)
    status = $evm.root['ssh_command_status']

    # pull and inspect our results if we succeeded
    if status
      results = $evm.root['ssh_results']
      return results
    else
      log(:error, "run_ssh: Command #{shell_command} failed.  Returning nil.")
      return nil
    end
  rescue => err
    log(:error, "run_ssh: Unable to run command: #{shell_command}.  Returning nil.")
    return nil
  end
end

# ====================================
# begin main method
# ====================================

begin
  # dump root/object attributes
  [ 'root', 'object' ].each { |object_type| $evm.instantiate("/Common/Log/DumpAttrs?object_type=#{object_type}") if @debug == true }

  # ensure we are using this method in the proper context
  case $evm.root['vmdb_object_type']
    when 'miq_provision'
      prov = $evm.root['miq_provision']
      vm   = prov.vm || prov.destination rescue nil
    when 'vm'
      vm   = $evm.root['vm']
      prov = vm.miq_provision rescue nil
    else
      raise "Invalid $evm.root['vmdb_object_type']: #{$evm.root['vmdb_object_type']}"
  end

  if vm && prov
    log(:info, "Inspecting VM: #{vm.inspect}") if @debug
    log(:info, "Inspecting Provisioning Object: #{prov.inspect}") if @debug

    # get ssh connection variables
    host_ip = vm.ipaddresses.first

    # install the puppet package first
    if host_ip.nil?
      raise "Missing host_ip" if host_ip.nil?
    else
      # set an empty array for our commands
      # NOTE: the commands should be pushed into the array in the order in which they are to be ran
      puppet_config_commands = []

      # puppet_agent_pkg install command
      puppet_agent_pkg = $evm.object['puppet_agent_pkg']
      raise "Unable to determine puppet_agent_pkg" if puppet_agent_pkg.nil?
      puppet_config_commands.push("yum install -y #{puppet_agent_pkg} --nogpgcheck")

      # puppet configuration (modifies /etc/puppetlabs/puppet/puppet.conf file)
      puppet_config_attrs = {
        :server    => $evm.object['puppet_master_server'],
        :ca_server => $evm.object['puppet_ca_server']
      }
      puppet_config_attrs.each do |k,v|
        log(:info, "puppet_config_attrs: Key: <#{k}>, Value: <#{v}>")

        if v.nil?
          raise "Missing value for Key: <#{k}>" if v.nil?
        else
          log(:info, "Setting puppet config option: #{k.to_s}=#{v.to_s}")
          puppet_config_commands.push("puppet config --section agent set #{k.to_s} #{v.to_s}")
        end
      end

      # create certificate request
      # NOTE: although starting the service makes the certificate request, this ensures the request exists
      # by the time we go to sign the certificate
      # NOTE: we also exit with code 0 because we know this returns a 1
      puppet_config_commands.push("puppet agent -tv --noop --waitforcert=0; exit 0")

      # start/enable puppet service
      puppet_agent_service = $evm.object['puppet_agent_service']
      raise "Unable to determine puppet_agent_service" if puppet_agent_service.nil?
      puppet_config_commands.push("puppet resource service #{puppet_agent_service} ensure=running enable=true")
    end

    # loop through commands to finish puppet configuration
    puppet_config_commands.each do |command|
      command_results = run_ssh(host_ip, command, 120)
      if command_results
        log(:info, "Inspecting command_results: #{command_results.inspect}") if @debug
      else
        raise "Unable to successfully complete command: <#{command}>"
      end
    end
  else
    raise "Could not find provisioning object or VM"
  end

  # ====================================
  # exit method
  # ====================================

  exit MIQ_OK

# set ruby rescue behavior
rescue => err
  # set error message
  message = "Unable to successfully complete method: <b>#{@method}</b>.  Error: #{err}"

  # log what we failed
  log(:error, message)
  log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")

  # get errors variables (or create new hash) and set message
  if prov
    errors                                = prov.get_option(:errors)
    errors[:puppet_configure_agent_error] = message
    prov.set_option(:errors, errors)
  end

  # exit with something other than MIQ_OK status
  exit MIQ_ABORT
end
