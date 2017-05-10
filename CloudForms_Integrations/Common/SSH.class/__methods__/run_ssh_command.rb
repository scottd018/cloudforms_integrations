#
# Description: Runs an SSH command
#
# Input Requirements:
#   - ssh_command:   Must input the SSH command to run
#   - ssh_auth_type: Must input the authentication type (password vs. key)
#   - ssh_host:      Must input the IP/Hostname of system to run command against
#
# Other Inputs (Optional):
#   - ssh_timeout: Set the SSH timeout (Default set below in 'Inputs' section)
#   - ssh_debug: Set the debug to true/false to increase logging (Default set below in 'Inputs' section)
#   - ssh_valid_exit_code: Should default to '0' unless you have a super crazy script with weird exit codes.
#     The SSH method will fail unless this exit code matches.
#   - ssh_fail_on_invalid_exit_code: Defaults to true, but can be overridden with this input.  If false, you won't see any errors
#     in the automation.log and all error handling will be performed by the root object.
#   - ssh_username: Set the user for the SSH connection (defaults to automate model user in _Variables domain)
#   - ssh_password: Set the password of the user for the SSH connection (defaults to automate mode password in _Variables domain)
#     CAUTION: must be sent as a string in cleartext for now
#   - ssh_key: Set the SSH private key of the user for the SSH connection (defaults to automate mode private key in _Variables domain)
#     CAUTION: must be sent as a string in cleartext for now
#
# Notes:
#   - SSH Variables are stored in the variables domain.  You should have an SSH Service account to use this.
#   - Ideally, you should be able to pass in a specific user/password/key, but for now, decrypting password
#     with MiqPassword is problematic when attempting via inputs.
#   - Should be used as a reusable method and called from automate.
# 
# Usage:
#   - Can be called as follows:
#
#   ssh_method_path = "/System/CommonMethods/SSH/RunSshCommand"
#   ssh_query = {
#     :ssh_host      => '192.168.50.135',
#     :ssh_command   => "echo \'Hello World\'",
#     :ssh_timeout   => 600,
#     :ssh_auth_type => 'password',
#     :ssh_debug     => true
#   }.to_query
#   $evm.instantiate(ssh_method_path + '?' + ssh_query)
# 
#   - Or you could use the full URI as well:
#
#   ssh_method_path = "/System/CommonMethods/SSH/RunSshCommand"
#   $evm.instantiate(ssh_method_path + '?command=echo \'Hello World\'&ssh_host=1.1.1.1&ssh_auth_type=password')
#
# Return Values (set on the $evm.root object):
#   - ssh_command_status: returns true on success, false on failure (only returns if ssh_fail_on_invalid_exit_code is true)
#   - ssh_results: returns results
#
# TODO:
#   - A better way to do this may be to get rid of the timeout altogether, run the command in the background, and monitor
#     the session PID.  This would free up the worker rather than locking it up for the entirety of the command.  The current
#     state isn't bad for small environments, but could prove to be problematic for large enterprises.
#
# Author: Dustin Scott, Red Hat
#

begin
  # ====================================
  # set gem requirements
  # ====================================

  require 'net/ssh'

  # ====================================
  # set global method variables
  # ====================================

  # set method variables
  @method = $evm.current_method
  @org    = $evm.root['tenant'].name
  @debug  = $evm.inputs['rest_debug'] || false

  # log entering method
  $evm.log(:info, "Entering sub-method <#{@method}>")
  
  # ====================================
  # define methods
  # ====================================
  
  # define execute_ssh method to determine what happens when we open the ssh connection
  # NOTE: more generic to support both key and password based authentication
  def execute_ssh(ssh, ssh_command)
    $evm.log(:info, "Inspecting ssh: #{ssh.inspect}") if @debug == true
    stdout_data = ""
    stderr_data = ""
    exit_code = nil
    exit_signal = nil
    ssh.open_channel do |channel|
      channel.exec(ssh_command) do |ch, success|
        unless success
          raise "FAILED: couldn't execute command (ssh.channel.exec)"
        end
      
        channel.on_data do |ch,data|
          stdout_data += data
        end
      
        channel.on_extended_data do |ch,type,data|
          stderr_data += data
        end

        channel.on_request("exit-status") do |ch,data|
          exit_code = data.read_long
        end

        channel.on_request("exit-signal") do |ch, data|
          exit_signal = data.read_long
        end
      end
    end
    ssh.loop
    
    # create a hash of results
    results = {
      :stdout_data => stdout_data,
      :stderr_data => stderr_data,
      :exit_code   => exit_code,
      :exit_signal => exit_signal
    }
      
    # log and return the results
    results.each { |key,value| $evm.log(:info, "#{key} result: #{value}") unless (value.nil? | value.blank?) } if @debug == true
    return results
  end

  # ====================================
  # set variables
  # ====================================
  
  # log setting variables
  $evm.log(:info, "Setting variables for sub-method: <#{@method}>")
  
  # set input variables
  ssh_host                      = $evm.inputs['ssh_host'] rescue nil
  ssh_command                   = CGI.unescape($evm.inputs['ssh_command']) rescue nil
  ssh_timeout                   = $evm.inputs['ssh_timeout'] rescue nil
  ssh_valid_exit_code           = $evm.inputs['ssh_valid_exit_code'] rescue nil
  ssh_auth_type                 = $evm.inputs['ssh_auth_type'] rescue nil
  ssh_fail_on_invalid_exit_code = $evm.inputs['ssh_fail_on_invalid_exit_code'] rescue nil
  raise "Unable to determine ssh_host" if ssh_host.nil?
  raise "Unable to determine ssh_command" if ssh_command.nil?
  raise "Unable to determine ssh_timeout" if ssh_timeout.nil?
  raise "Unable to determine ssh_valid_exit_code" if ssh_valid_exit_code.nil?
  raise "Unable to determine ssh_fail_on_invalid_exit_code" if ssh_fail_on_invalid_exit_code.nil?
    
  # log warning message if we have an excessive ssh_timeoute value
  if ssh_timeout > 60
    ssh_timeout_warn_msg  = "SSH Timeout variable [ssh_timeout] value set to <#{ssh_timeout}>.  "
    ssh_timeout_warn_msg += "This can potentially cause undesired results by locking up a CFME worker for <#{ssh_timeout}> seconds"
    $evm.log(:warn, ssh_timeout_warn_msg)
  end
    
  # dynamically set variable strings to pull later based on our object type
  case $evm.root['vmdb_object_type']
  when 'vm'
    # if we have a vm object, use the post-provision service account
    ssh_acct_string = 'default_user'
  when 'miq_provision'
    # if we have a provision object, use the provision service account
    ssh_acct_string = 'default_user'
  else
    raise "Invalid $evm.root['vmdb_object_type']: #{$evm.root['vmdb_object_type']}"
  end
  
  # validate that we didn't specify a username without a private key or password
  if $evm.inputs['ssh_username'] == 'default'
    ssh_username = $evm.object[ssh_acct_string] rescue nil
  else
    ssh_username = $evm.inputs['ssh_username'] rescue nil
    if ssh_auth_type == 'password'
      raise "Username <#{ssh_username}> specified without a password for auth_type <#{ssh_auth_type}>" if $evm.inputs['ssh_password'] == 'default'
    elsif ssh_auth_type == 'key'
      raise "Username <#{ssh_username}> specified without an ssh key for auth_type <#{ssh_auth_type}>" if $evm.inputs['ssh_key'] == 'default'
    else
      raise "Invalid <ssh_auth_type> variable passed into method <#{@method}>.  Supported values are <password> or <key>."
    end
  end
  raise "Unable to determine ssh_username" if ssh_username.nil?    
  
  # ====================================
  # begin main method
  # ====================================

  # log entering main method
  $evm.log(:info, "Running main portion of ruby code on sub-method: <#{@method}>")

  # start an ssh session based on password or key based authentication
  $evm.log(:info, "Calling SSH: ssh_auth_type: <#{ssh_auth_type}>, ssh_command: <\"#{ssh_command}\">, ssh_timeout: <#{ssh_timeout}>, ssh_username: <#{ssh_username}>, ssh_host: <#{ssh_host}>")
  if ssh_auth_type == 'password'
    # grab the password (use default account password from automate, but user can override with input)
    $evm.inputs['ssh_password'] == 'default' ? ssh_password = $evm.object.decrypt('default_password') : ssh_password = $evm.inputs['ssh_password'] rescue nil
    raise "Unable to determine password for user <#{ssh_username}>" if ssh_password.nil?
      
    # wrap the ssh command with timeout to make sure it doesn't lock up the worker
    Timeout::timeout(ssh_timeout) do
      begin
        Net::SSH.start(ssh_host, ssh_username, :password => ssh_password, :paranoid => false) do |ssh|
          ssh_results = execute_ssh(ssh, ssh_command)
          $evm.root["ssh_results"] = ssh_results unless ssh_results.nil?
          if ssh_fail_on_invalid_exit_code == true || ssh_fail_on_invalid_exit_code == 'true'
            raise "Improper exit code #{ssh_results[:exit_code]}" unless ssh_results[:exit_code] == ssh_valid_exit_code
          end
        end
      rescue Timeout::Error
        raise "SSH Command timeout in method <#{@method}>:  Exceeded timeout of <#{ssh_timeout}> seconds"
      end
    end
  elsif ssh_auth_type == 'key'
    # grab the ssh key (use default ssh key from automate, but user can override with input)
    $evm.inputs['ssh_key'] == 'default' ? ssh_key = $evm.object.decrypt('ssh_key').gsub(/:/,"\n") : ssh_key = CGI.unescape($evm.inputs['ssh_key']) rescue nil
    raise "Unable to determine SSH key for user <#{ssh_username}>" if ssh_key.nil?

    # wrap the ssh command with timeout to make sure it doesn't lock up the worker
    Timeout::timeout(ssh_timeout) do
      begin
        Net::SSH.start(ssh_host, ssh_username, :keys => [], :key_data => ssh_key, :keys_only => true, :paranoid => false) do |ssh|
          ssh_results = execute_ssh(ssh, ssh_command)
          $evm.root["ssh_results"] = ssh_results unless ssh_results.nil?
          if ssh_fail_on_invalid_exit_code == true || ssh_fail_on_invalid_exit_code == 'true'
            raise "Improper exit code #{ssh_results[:exit_code]}" unless ssh_results[:exit_code] == ssh_valid_exit_code
          end
        end
      rescue Timeout::Error
        raise "SSH Command timeout in method <#{@method}>:  Exceeded timeout of <#{ssh_timeout}> seconds"
      end
    end
  end

  # ====================================
  # log end of method
  # ====================================
  
  # log exiting method and let the root object know we succeeded
  $evm.log(:info, "Exiting sub-method <#{@method}>")
  $evm.root["ssh_command_status"] = true
  exit MIQ_OK

rescue => err
  # set error message
  message = "Error in method <#{@method}>: #{err}"
  
  # log what we failed
  $evm.log(:error, message)
  $evm.log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")
  
  # let the root object know that we failed
  $evm.root["ssh_command_status"] = false
        
  # log exiting method and exit with MIQ_WARN status
  $evm.log(:info, "Exiting sub-method <#{@method}>")
  exit MIQ_WARN
end
