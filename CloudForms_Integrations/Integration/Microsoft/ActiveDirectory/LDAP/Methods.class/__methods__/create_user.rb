#
# Description: Creates a User in Active Directory
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
  
  # log bookends
  def log_bookend(status)
    $evm.log('info', "====================================")
    $evm.log('info', "#{@org} Customization: #{status.capitalize} #{@method} method")
    $evm.log('info', "====================================")
  end

  # dump root attributes
  def dump_root()
    $evm.log('info', "Root:<$evm.root> Begin $evm.root.attributes")
    $evm.root.attributes.sort.each { |k, v| $evm.log('info', "Root:<$evm.root> Attribute - #{k}: #{v}") }
    $evm.log('info', "Root:<$evm.root> End $evm.root.attributes")
    $evm.log('info', "")
  end
  
  # call_ldap
  def call_ldap(ad_username, ad_password, ad_basedn, ad_server, ad_ldap_port, create_user_dn, create_user_attrs)
    # setup authentication to ldap
    ldap = Net::LDAP.new(
      :host => ad_server,
      :port => ad_ldap_port,
      :encryption => {
        :method => :simple_tls
       },
      :auth => {
        :method => :simple,
        :username => "cn=#{ad_username},ou=Service Accounts,ou=Users,ou=Scott-Net,#{ad_basedn}",
        :password => ad_password
      }
    )
    
    # search ldap for user
    log(:info, "Searching LDAP server: #{ad_server} basedn: #{ad_basedn} for user: #{create_user_attrs[:cn]}")
    filter = Net::LDAP::Filter.eq('cn', create_user_attrs[:cn])
    entry = ldap.search(:base => ad_basedn, :filter => filter)

    if entry.size.zero?
      # add to ldap only if we found no computer_name matches in ldap
      log(:info, "Inspecting entry for user <#{create_user_attrs[:cn]}>: #{entry.inspect}") if @debug == true
      log(:info, "Calling ldap:<#{ad_server}> dn:<#{create_user_dn}> attributes:<#{create_user_attrs}>")
      ldap.add(:dn => create_user_dn, :attributes => create_user_attrs)
      result = ldap.get_operation_result.code
    else
      # do not add to ldap if we have found computer_name matches in ldap
      log(:warn, "Skipping ldap:<#{ad_server}> dn:<#{create_user_dn}> attributes:<#{create_user_attrs}>.  Entry already exists.")
      result = 68
    end

    if result.zero?
      log(:info, "Successfully added user:<#{create_user_attrs[:cn]}> to Active Directory")
    else
      log(:warn, "Failed to add user:<#{create_user_attrs[:cn]}> to Active Directory with result code #{result}")
    end
    return result
  end
  
  # check variables hash to make sure we have valid values
  def check_vars_hash(hash)
    begin
      log(:info, "Checking variables for valid values...")
      hash.each do |k,v|
        raise "Missing value: <#{v}> for key: <#{k}>" if v.nil?
        log(:info, "Found value: <#{v}> for key: <#{k}>") if @debug == true
      end
      return true
    rescue => err
      return err
    end
  end
  
  # ====================================
  # log beginning of method
  # ====================================
        
  # set method variables
  @method = $evm.current_method
  @org = $evm.root['tenant'].name
  @debug = true
  
  # log entering method and dump root attributes
  log_bookend("enter")
  dump_root
  
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
  end
  
  # set active directory variables
  ad_vars = { 
    :ad_server => $evm.object['ad_server'],
    :ad_username => $evm.object['ad_username'],
    :ad_password => $evm.object.decrypt('ad_password'),
    :ad_basedn => $evm.object['ad_basedn'],
    :ad_ldap_port => $evm.object['ad_ldap_port'],
    :ad_domain => $evm.object['ad_domain']
  }
  check_ad_vars = check_vars_hash(ad_vars)
  raise check_ad_vars unless check_ad_vars == true
  
  # set active directory user variable inputs from dialog
  user_vars = {
    :first_name => $evm.root['dialog_first_name'],
    :last_name => $evm.root['dialog_last_name'],
    :password => $evm.root.decrypt('dialog_password'),
    :reenter_password => $evm.root.decrypt('dialog_reenter_password'),
    :user_type => $evm.root['dialog_user_type']
  }
  check_user_vars = check_vars_hash(user_vars)
  raise check_user_vars unless check_user_vars == true
  raise "Password input from user: <#{first_name.capitalize} #{last_name.capitalize} does not match" unless user_vars[:password] == user_vars[:reenter_password]
  
  # create variables based upon the user_type selected in the dialog
  base_username = user_vars[:last_name][0,7].downcase.to_s + user_vars[:first_name][0].downcase.to_s
  log(:info, "Base username for user creation is: <#{base_username}>") if @debug == true
  if user_vars[:user_type] == 'standard_user'
    # set ou, username based on standard user type
    create_user = base_username
    create_user_ou = $evm.object['ad_std_user_ou']
    create_user_display_name = "#{user_vars[:first_name].capitalize} #{user_vars[:last_name].capitalize}"
  elsif user_vars[:user_type] == 'admin_user'
    # set ou and username based on admin user type
    create_user = 'admin.' + base_username
    create_user_ou = $evm.object['ad_admin_user_ou']
    create_user_display_name = "#{user_vars[:first_name].capitalize} #{user_vars[:last_name].capitalize} (Admin)"
  elsif user_vars[:user_type] = 'service_account'
    raise "Service Account creation not implemented yet"
  else
    raise "Invalid user_type selected.  Please update method <#{@method}> to support user_type <#{user_type}>"
  end
  raise "Unable to determine Organizational Unit to add user <#{ad_username}> to" if create_user_ou.nil?
  
  # create a hash of attributes to set when creating the user
  create_user_dn = "cn=#{create_user_display_name},#{create_user_ou}"
  create_user_attrs = {
    :cn => create_user_display_name,
    :displayName => create_user_display_name,
    :objectclass => [ 'top', 'person', 'organizationalPerson', 'user' ],
    :givenName => user_vars[:first_name].capitalize,
    :sn => user_vars[:last_name].capitalize,
    #:userPassword => user_vars[:password],
    :sAMAccountName => create_user,
    :mail => "#{create_user}\@#{ad_vars[:ad_domain]}",
    :userPrincipalName => "#{create_user}\@#{ad_vars[:ad_domain]}",
    :userAccountControl => '66048'
  }
  
  # ====================================
  # begin main method
  # ====================================

  # log entering main method
  log(:info, "Running main portion of ruby code on method: #{@method}")
  
  # create the ldap user
  call_ldap(ad_vars[:ad_username], ad_vars[:ad_password], ad_vars[:ad_basedn], ad_vars[:ad_server], ad_vars[:ad_ldap_port], create_user_dn, create_user_attrs)

  # ====================================
  # log end of method
  # ====================================
  
  # log exiting method and exit with MIQ_OK status
  log_bookend("exit")
  exit MIQ_OK

# set ruby rescue behavior
rescue => err
  # set error message
  message = "Error in method #{@method}: #{err}"
  
  # log what we failed
  log(:error, message)
  log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")

  # get errors variables (or create new hash)
  errors = prov.get_option(:errors) || {} rescue nil
  
  # set hash with this method error
  errors[:my_error] = message
  
  # set errors option
  prov.set_option(:errors, errors) if prov
        
  # log exiting method and exit with something besides MIQ_OK
  log_bookend("exit")
  exit MIQ_ABORT
end
