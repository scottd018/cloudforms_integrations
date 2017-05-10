#
# Description: Deletes the computer object from AD/LDAP
# Author: Dustin Scott, Red Hat
#

begin
  # ====================================
  # set gem requirements
  # ====================================

  require 'rubygems'
  require 'net/ldap'
  
  # ====================================
  # define methods
  # ====================================
  
  # define log method
  def log(level, msg)
    $evm.log(level,"#{@org} Customization: #{msg}")
  end
  
  # call_ldap
  def call_ldap(computer_name, servername, port, username, password, basedn)
    # setup authentication to ldap
    ldap = Net::LDAP.new :host => servername,
                         :port => port,
                         :encryption => :simple_tls,
                         :auth => {
                           :method => :simple,
                           :username => username,
                           :password => password
                         }

    # search for computer_name
    log(:info, "Searching LDAP server: #{servername} basedn: #{basedn} for computer: #{computer_name} with user #{username}")
    filter = Net::LDAP::Filter.eq("cn", computer_name)
    scope = Net::LDAP::SearchScope_WholeSubtree
    computer_dn = nil
    search_results = ldap.search(:base => basedn, :filter => filter, :scope => scope) {|entry| computer_dn = entry.dn }
    log(:info, "Inspecting search_results: #{search_results.inspect}") if @debug == true
    
    # simply exit if we don't find the object.  that's what we were trying to do anyway.  no big deal if it's missing
    if computer_dn.blank?
      log(:warn, "computer_dn: #{computer_dn} not found.  Exiting.")
      exit MIQ_OK
    else
      # some logging
      log(:info, "Found computer_dn: #{computer_dn.inspect}")
      log(:info, "Deleting computer_dn from LDAP")
    
      # perform deletion of ldap computer object
      ldap.delete(:dn => computer_dn)
      result = ldap.get_operation_result.code
      if result.zero?
        log(:info, "Successfully deleted computer_dn: #{computer_dn} from LDAP Server")
      else
        log(:warn, "Failed to delete computer_dn: #{computer_dn} from LDAP Server")
      end
    end
    return result
  end
  
  # ====================================
  # log beginning of method
  # ====================================
  
  # set method variables
  @method = $evm.current_method
  @org = $evm.root['tenant'].name rescue nil
  @debug = false
    
  # log entering method and dump root/object attributes
  $evm.instantiate('/System/CommonMethods/Log/LogBookend' + '?' + { :bookend_status => :enter, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  [ 'root', 'object' ].each { |object_type| $evm.instantiate("/System/CommonMethods/Log/DumpAttrs?object_type=#{object_type}") if @debug == true }

  # ====================================
  # set variables
  # ====================================

  # log setting variables
  log(:info, "Setting variables for method: #{@method}")

  # set provisioning object variables
  case $evm.root['vmdb_object_type']
  when 'vm'
    vm = $evm.root['vm'] rescue nil
    prov = vm.miq_provision rescue nil
  when 'miq_provision'
    prov = $evm.root['miq_provision'] rescue nil
    vm = prov.destination rescue nil
  else
    raise "Invalid $evm.root['vmdb_object_type']: #{$evm.root['vmdb_object_type']}"
  end
  raise 'Unable to determine VM' if vm.nil?
  computer_name = vm..name
  raise "computer_name not found" if computer_name.nil?
  log(:info, "Found VM: <#{computer_name}>")
  
  # get ldap options from the current object
  servername = $evm.object['ad_server'] rescue nil
  port = $evm.object['ad_ldap_port'] rescue ni
  username = $evm.object['ad_username'] rescue nil
  basedn = $evm.object['ad_basedn'] rescue nil
  password = $evm.object.decrypt('ad_password') rescue nil
  raise "servername not found" if servername.nil?
  raise "port not found" if port.nil?
  raise "username not found" if username.nil?
  raise "password not found" if password.nil?
  
  # debug logging
  if @debug == true
    log(:info, "Inspecting VM: #{vm.inspect}") unless vm.nil?
  end  
  
  # ====================================
  # begin main method
  # ====================================

  # log entering main method
  log(:info, "Running main portion of ruby code on method: #{@method}")
  
  # make ldap call to create object
  result = call_ldap(computer_name, servername, port, username, password, basedn)
  
  # inspect the results
  log(:info, "Inspecting delete results: #{result.inspect}") if @debug == true

  # ====================================
  # log end of method
  # ====================================
  
  # log exiting method and exit with MIQ_OK status
  $evm.instantiate('/System/CommonMethods/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_OK

# set ruby rescue behavior
rescue => err 
  # set message
  message = "Unable to successfully complete method: <b>#{@method}</b>.  Could not delete computer #{computer_name} from Active Directory server #{servername}."

  # log what we failed
  log(:warn, message)
  log(:warn, "[#{err}]\n#{err.backtrace.join("\n")}")

  # get errors variables (or create new hash)
  retire_errors = prov.get_option(:retire_errors) rescue nil
  retire_errors ||= {}
  
  # set hash with this method error
  retire_errors[:delete_from_ldap_error] = message
  
  # set errors option
  prov.set_option(:retire_errors, retire_errors) if prov
        
  # log exiting method and exit with something besides MIQ_OK
  $evm.instantiate('/System/CommonMethods/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_WARN
end
