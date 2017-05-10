#
# Description:   Register the Client with the IDM server
# Author:        Dustin Scott, Red Hat
# Creation Date: 17-Jan-2017
# Requirements:
#   - Network connectivity present
#   - Port 22 open between CloudForms Worker/Client
#   - Username/Password stored in /Integration/OperatingSystems/Linux (for SSH)
#   - Access to base Satellite OS Content Views (registered with Satellite)
#   - dns_domain from prov object to determine FQDN (used to determine doman/realm for IDM server)
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
      vm   = prov.vm rescue nil
      vm ||= prov.destination rescue nil
    when 'vm'
      vm   = $evm.root['vm']
      prov = vm.miq_provision rescue nil
    else
      raise "Invalid $evm.root['vmdb_object_type']: #{$evm.root['vmdb_object_type']}"
  end

  if vm && prov
    log(:info, "Inspecting VM: #{vm.inspect}") if @debug
    log(:info, "Inspecting Provisioning Object: #{prov.inspect}") if @debug

    # get the vm fqdn
    vm_name = vm.name.downcase
    domain  = prov.get_option(:dnsdomain) || prov.get_option(:dns_domain)
    if domain
      fqdn = "#{vm_name}.#{domain}"
    else
      raise "Missing domain via: prov.get_option(:dnsdomain) || prov.get_option(:dns_domain)"
    end
    log(:info, "VM FQDN: <#{fqdn}>")

    # get ssh connection variables
    host_ip = vm.ipaddresses.first

    # get the configuration from the puppet master
    if host_ip.nil?
      raise "Missing host_ip" if host_ip.nil?
    else
      # set idm registration variables
      idm_register_attrs = {
        :idm_server           => $evm.object['idm_server'],
        :idm_user             => $evm.object['idm_user'],
        :idm_password         => $evm.object.decrypt('idm_password'),
        :idm_client_packages  => $evm.object['idm_client_packages'],
        :idm_update_dns       => $evm.object['idm_update_dns'],
        :idm_config_mkhomedir => $evm.object['idm_config_mkhomedir'],
        :idm_config_ssh       => $evm.object['idm_config_ssh'],
        :idm_domain           => prov.get_option(:dnsdomain)
      }

      # validate that we successfully pulled all required variables to continue
      idm_register_attrs.each do |k,v|
        log(:info, "idm_register_attrs: Key: <#{k}>, Value: <#{v}>")
        raise "Missing value for Key: <#{k}>" if v.nil?
      end

      # install the idm packages
      install_pkg_cmd             = "yum -y install #{idm_register_attrs[:idm_client_packages]}"
      install_idm_package_results = run_ssh(host_ip, install_pkg_cmd, 120)
      if install_idm_package_results
        log(:info, "Inspecting install_idm_package_results: #{install_idm_package_results.inspect}") if @debug
      else
        raise "Unable to install IDM packages via command: <#{install_pkg_cmd}>"
      end

      # set base command for registration and append options based on boolean values
      idm_register_base_command = "ipa-client-install --principal #{idm_register_attrs[:idm_user]} \
      --password \'#{idm_register_attrs[:idm_password]}\' \
      --server   #{idm_register_attrs[:idm_server]} \
      --domain   #{idm_register_attrs[:idm_domain]} \
      --realm    #{idm_register_attrs[:idm_domain].upcase} \
      --hostname #{fqdn} \
      --unattended"

      # append options to end of base command
      idm_register_base_command += " --enable-dns-updates" if idm_register_attrs[:idm_update_dns]      == true
      idm_register_base_command += " --mkhomedir"          if idm_register_attrs[:idm_config_mkhomdir] == true
      idm_register_base_command += " --no-ssh"             unless idm_register_attrs[:idm_config_ssh]  == true

      # run the idm registration command
      idm_register_results = run_ssh(host_ip, idm_register_base_command, 120)
      if idm_register_results
        log(:info, "Inspecting idm_register_results: #{idm_register_results.inspect}") if @debug
      else
        raise "Unable to register with IDM via command: <#{idm_register_base_command}>"
      end
    end
  else
    raise "Could not find VM or Provisioning Object"
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
    errors                             = prov.get_option(:errors)
    errors[:idm_register_client_error] = message
    prov.set_option(:errors, errors)
  end

  # exit with something other than MIQ_OK status
  exit MIQ_ABORT
end
