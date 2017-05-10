#
# Description: Adds the computer object to AD/LDAP
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
  def call_ldap(computer_name, servername, port, username, password, basedn, dn)  
    # setup authentication to ldap
    ldap = Net::LDAP.new :host => servername,
                         :port => port,
                         :encryption => {
                             :method => :simple_tls
                         },
                         :auth => {
                             :method => :simple,
                             :username => username,
                             :password => password
                         }

    # configure ldap attributes
    attributes = {
      :cn => computer_name,
      :objectclass => [ 'top', 'computer' ],
      :samaccountname => "#{computer_name}$",
      :useraccountcontrol => '4128'
    }
    
    # search ldap for computer_name
    log(:info, "Searching LDAP server: #{servername} basedn: #{basedn} for computer: #{computer_name}")
    filter = Net::LDAP::Filter.eq('cn', computer_name)
    entry = ldap.search(:base => basedn, :filter => filter)

    if entry.size.zero?
      # add to ldap only if we found no computer_name matches in ldap
      log(:info, "Calling ldap:<#{servername}> dn:<#{dn}> attributes:<#{attributes}>")
      ldap.add(:dn => dn, :attributes => attributes)
      result = ldap.get_operation_result.code
    else
      # do not add to ldap if we have found computer_name matches in ldap
      log(:warn, "Skipping ldap:<#{servername}> dn:<#{dn}> attributes:<#{attributes}>.  Entry already exists.")
      result = 68
    end

    if result.zero?
      log(:info, "Successfully added computer:<#{computer_name}> to LDAP Server")
    else
      log(:error, "Failed to add computer:<#{computer_name}> to LDAP Server with result code #{result}")
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
  raise 'Unable to find provisioning object' if prov.nil?

  # get computer attributes
  tags = prov.get_tags rescue nil
  os = prov.source.platform rescue nil
  os == 'windows' ? computer_name = prov.get_option(:host_name).to_s.strip.upcase : computer_name = prov.get_option(:host_name).to_s.strip
  system_type = tags[:system_type] rescue nil
  
  # get active directory options from the current object
  servername = $evm.object['ad_server'] rescue nil
  port = $evm.object['ad_ldap_port'] rescue nil
  username = $evm.object['ad_username'] rescue nil
  basedn = $evm.object['ad_basedn'] rescue nil
  password = $evm.object.decrypt('ad_password') rescue nil
  
  # check for required variables
  raise 'Unable to determine os' if os.nil?
  raise 'Unable to determine system_type' if system_type.nil?
  raise "computer_name not found" if computer_name.nil?
  raise "servername not found" if servername.nil?
  raise "port not found" if port.nil?
  raise "username not found" if username.nil?
  raise "password not found" if password.nil?
  log(:info, "Found VM: <#{computer_name}>")

  # ====================================
  # begin main method
  # ====================================

  # log entering main method
  log(:info, "Running main portion of ruby code on method: #{@method}")

  # get parameters
  case system_type
    when 'app_server' then ou_prefix = 'Application'
    when 'db_server' then ou_prefix = 'Database'
    when 'web_server' then ou_prefix = 'Web'
  end
  
  # set the ou/dn based on our variables
  ou = "ou=#{ou_prefix},ou=#{os.capitalize},ou=Servers,ou=Example-Com,#{basedn}"
  dn = "cn=#{computer_name},#{ou}"

  # make ldap call to create object
  result = call_ldap(computer_name, servername, port, username, password, basedn, dn)
      
  # inspect the results
  log(:info, "Inspecting add results: #{result.inspect}") if @debug == true

  # ====================================
  # log end of method
  # ====================================
  
  # log exiting method and exit with MIQ_OK status
  $evm.instantiate('/System/CommonMethods/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_OK

# set ruby rescue behavior
rescue => err
  log(:error, "#{err.class} #{err}")
  log(:error, "#{err.backtrace.join("\n")}")
  
  # create log message
  log(:error, "Unable to create AD object for VM #{computer_name}")
  
  # get errors variables (or create new hash) and set message
  message = "Unable to successfully complete method: <b>#{@method}</b>.  Could not add computer #{computer_name} to Active Directory server #{servername}."
  errors = prov.get_option(:errors) || {}
  
  # set hash with this method error
  errors[:add_computer_error] = message if prov
  
  # log exiting method and exit with something besides MIQ_OK
  $evm.instantiate('/System/CommonMethods/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_WARN
end
