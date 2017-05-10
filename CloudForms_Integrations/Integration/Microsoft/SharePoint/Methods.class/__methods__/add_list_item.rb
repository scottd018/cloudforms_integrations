#
# Description: Adds a SharePoint list item
# Notes: 
# - Use #add message when calling the instance
# - Tested on SharePoint 2010 and SharePoint 2013
# - Works with NTLM, Basic, and Digest authentication only
#

begin
  # ====================================
  # set gem requirements
  # ====================================
  
  require 'httpclient'
  require 'rubyntlm'
  require 'json'
  
  # ====================================
  # define methods
  # ====================================
  
  # define log method
  def log(level, msg)
    $evm.log(level,"#{@org} Customization: #{msg}")
  end
  
  # post data to sharepoint list
  def update_sp_list(sp_hash, sp_username, sp_password, url)
    # log what we are doing
    log(:info, "Updating SharePoint URL: #{url}")
    log(:info, "Updating with parameters: #{sp_hash.inspect}")
    
    # convert hash to json so that we can properly post
    sp_json_data = sp_hash.to_json
    
    # inspecting sp_json_data
    log(:info, "Inspecting sp_json_data: #{sp_json_data.inspect}")
    
    # set and inspect headers
    headers = {
      'Content-Type' => 'application/json',
      'X-FORMS_BASED_AUTH_ACCEPTED' => 'f'
    }
    log(:info, "Inspecting headers: #{headers.inspect}")
    
    # create http object
    client = HTTPClient.new
    
    # post data to the sharepoint url
    # CAUTION: supports NTLM, Basic, and Digest.  If SharePoint is using something complex such as
    # ADFS with STS/SAML tokens, please re-evaluate or get an exception to allow posting account to 
    # talk via a supported authentication means
    client.set_auth(nil, sp_username, sp_password)
    client.post(url, sp_json_data, headers)
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

  # set variables related to provisioning
  case $evm.root['vmdb_object_type']
  when 'vm'
    vm = $evm.root['vm']
    prov = vm.miq_provision
  when 'miq_provision'
    prov = $evm.root['miq_provision']
    vm = prov.destination
  else
    raise "Invalid $evm.root['vmdb_object_type']: #{$evm.root['vmdb_object_type']}"
  end
  
  # set sharepoint variables
  sp_username = $evm.object['sp_username']
  sp_password = $evm.object.decrypt('sp_password')
  sp_server = $evm.object['sp_server']
  sp_list_name = $evm.object['sp_list_name']
  sp_api_ref = $evm.object['sp_api_ref']
  sp_site = $evm.object['sp_site']
  sp_url_prefix = $evm.object['sp_url_prefix']
  
  # construct url we will talk to
  if sp_site.nil?
    # set variable for a default site list
    url = "#{sp_url_prefix}://#{sp_server}/#{sp_api_ref}/#{sp_list_name}"
  else
    # set variable for a list in a sub-site
    url = "#{sp_url_prefix}://#{sp_server}/#{sp_site}/#{sp_api_ref}/#{sp_list_name}"
  end
  
  # construct a hash of values to use to update sharepoint
  # NOTE: these correlate to fields in sharepoint.  Be careful, as the field name is not exact for specific field types. Examples are below:
  # Hostname = text
  # IPAddress = text
  # IPAssignmentValue = choice (reads IP Assignment in the Web UI - note the appended Value)
  # Title = text
  # Vault = choice
  sp_hash = {
    'Hostname' => vm.name,
    'IPAddress' => prov.get_option(:ip_addr),
    'IPAssignmentValue' => prov.get_option(:addr_mode),
    'Title' => "CloudForms - #{vm.name}",
    'Vault' => false
  }
   
  # ====================================
  # begin main method
  # ====================================

  # log entering main method
  log(:info, "Running main portion of ruby code on method: #{@method}")
  
  # perform sharepoint list update and inspect response
  response = update_sp_list(sp_hash, sp_username, sp_password, url)
  log(:info, "Inspecting SharePoint list update response: #{response.inspect}")
  
  # raise exception if we don't receive a 201 - created response
  raise "Invalid response #{response.status}" unless response.status == 201

  # ====================================
  # log end of method
  # ====================================
  
  # log exiting method and exit with MIQ_OK status
  $evm.instantiate('/System/CommonMethods/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_OK

# set ruby rescue behavior
rescue => err
  # set error message
  message = "Error in method: <b>#{@method}</b>:  #{err}"
  
  # log what we failed
  log(:warn, message)
  log(:warn, "[#{err}]\n#{err.backtrace.join("\n")}")

  # get errors variables (or create new hash)
  errors = prov.get_option(:errors) rescue nil
  errors ||= {}
  
  # set hash with this method error
  errors[:add_list_item_error] = message
  
  # set errors option
  prov.set_option(:errors, errors) if prov
        
  # log exiting method and exit with something besides MIQ_OK
  $evm.instantiate('/System/CommonMethods/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_WARN
end
