#
# Description:   Register client with Satellite6 Server
# Author:        Dustin Scott, Red Hat
# Creation Date: 4-Jan-2017
# Requirements:
#  - Network connectivity must be present (IP available and on the network)
#  - Must be able to communicate with Sat6 server over required ports/protocols
#  - SSH Password to the Client which is registering (set on Common SSH method)
#  - Activation Key from $evm.root:  key string is built with specific parameters/logic and set on $evm.root via build_activation_key method
#  - Selected activation key must enable satellite-tools repository to install katello-agent
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
def run_ssh(host, shell_command, ssh_timeout = 60)
  begin
    # define basic query
    ssh_query = {
      :ssh_host      => host,
      :ssh_auth_type => :password,     # password is set on ssh method (default per os during provisioning)
      :ssh_timeout   => ssh_timeout,
      :ssh_debug     => @debug,
      :ssh_command   => shell_command
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
      prov    = $evm.root['miq_provision']
      vm      = prov.vm rescue nil
      vm    ||= prov.destination rescue nil
    when 'vm'
      vm      = $evm.root['vm']
      prov    = vm.miq_provision rescue nil
    else
      raise "Invalid $evm.root['vmdb_object_type']: #{$evm.root['vmdb_object_type']}"
  end

  if vm && prov
    log(:info, "Inspecting VM: #{vm.inspect}") if @debug
    log(:info, "Inspecting Provisioning Object: #{prov.inspect}") if @debug

    # set satellite variables
    sat_register_attrs = {
      :sat_server       => $evm.object['sat_server'],
      :sat_organization => $evm.object['sat_organization'],
      :activation_key   => $evm.root['activation_key'],
      :host_ip          => vm.ipaddresses.first
    }

    # validate that we successfully pulled all require variables to continue
    sat_register_attrs.each do |k,v|
      log(:info, "sat_register_attrs: Key: <#{k}>, Value: <#{v}>")
      raise "Missing value for Key: <#{k}>" if v.nil?
    end

    # install the consumer rpm
    consumer_pkg_prefix = "katello-ca-consumer"
    consumer_install_results = run_ssh(sat_register_attrs[:host_ip], "yum remove -y #{consumer_pkg_prefix}-*; rpm -Uvh http://#{sat_register_attrs[:sat_server]}/pub/#{consumer_pkg_prefix}-latest.noarch.rpm")
    if consumer_install_results
      log(:info, "Inspecting consumer_install_results: #{consumer_install_results.inspect}") if @debug
    else
      raise "Unable to install Katello Consumer RPM"
    end

    # register with activation key
    register_results = run_ssh(sat_register_attrs[:host_ip], "subscription-manager register --org=#{sat_register_attrs[:sat_organization]} --activationkey=#{sat_register_attrs[:activation_key]} --force", 120)
    if register_results
      log(:info, "Inspecting register_results: #{register_results.inspect}") if @debug
    else
      raise "Unable to register with Satellite to Org: #{sat_register_attrs[:sat_organization]} with Key: #{sat_register_attrs[:activation_key]}"
    end
    
    # ensure repository is enabled
    repo_enable_results = run_ssh(sat_register_attrs[:host_ip], "subscription-manager repos --enable rhel-7-server-satellite-tools-6.2-rpms", 120)
    if repo_enable_results
      log(:info, "Inspecting repo_enable_results: #{repo_enable_results.inspect}") if @debug
    else
      raise "Unable to enable Satellite Tools repository"
    end

    # install katello-agent
    agent_install_results = run_ssh(sat_register_attrs[:host_ip], "yum -y install katello-agent", 120)
    if agent_install_results
      log(:info, "Inspecting agent_install_results: #{agent_install_results.inspect}") if @debug
    else
      raise "Unable to install katello-agent"
    end
  else
    raise "Unable to find provisioning object or VM"
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
    errors                                   = prov.get_option(:errors)
    errors[:satellite_register_client_error] = message
    prov.set_option(:errors, errors)
  end

  # exit with something other than MIQ_OK status
  exit MIQ_ABORT
end
