#
# Description: Remove the host record based on the vm name
# Author: Dustin Scott, Red Hat
#

begin
  # ====================================
  # set gem requirements
  # ====================================
  
  require 'rest_client'
  require 'json'
  require 'base64'
  
  # ====================================
  # define methods
  # ====================================
  
  # define log method
  def log(level, msg)
    $evm.log(level,"#{@org} Customization: #{msg}")
  end
  
  # method for using infoblox api call
  def call_infoblox(action, ref, content_type, return_type, body = nil, return_fields = nil)
    # set url
    if return_fields.nil?
      url = "#{@base_url}" + "#{ref}"
    else
      url = "#{@base_url}" + "#{ref}" + "\?_return_fields"
    end
       
    # set params for api call
    params = {
      :method => action,
      :url => url,
      :verify_ssl => false,
      :headers => {
        :content_type => content_type,
        :accept => return_type,
        :authorization  => "Basic #{Base64.strict_encode64("#{@username}:#{@password}")}"
      }
    }
  
    # generate payload data
    content_type == :json ? (params[:payload] = JSON.generate(body) if body) : (params[:payload] = body if body)
    log(:info, "Calling -> Infoblox: #{url} action: #{action} payload: #{params[:payload]}")
    response = RestClient::Request.new(params).execute
    raise "Failure <- Infoblox Response: #{response.code}" unless response.code == 200 || response.code == 201
    return response
  end

  # remove host record
  def remove_host(host_ref)
    begin
      log(:info, "ReclaimIP --> Delete Host Reference - #{host_ref}")
      
      # call infoblox to remove host record
      remove_host_response = call_infoblox(:delete, host_ref, :json, :json)
      log(:info, "Inspecting remove_host_response: #{remove_host_response.inspect}")
      return true
    rescue Exception => error
      log(:info, error.inspect)
      return false
    end
  end
  
  # fetch host_ref object based on vm fqdn
  def fetch_host_ref(vm_fqdn)
    begin
      log(:info, "ReclaimIP --> Fetch Host Reference - #{vm_fqdn}")

      # set extra options
      body = { :name => vm_fqdn }

      # call infoblox to fetch the network reference
      host_ref_response = call_infoblox(:get, 'record:host', :json, :json, body)
      host_ref = JSON.parse(host_ref_response).first['_ref'] rescue nil
      raise "Unable to find host reference for vm <#{vm_fqdn}>" if host_ref.nil?
      log(:info, "Inspecting host_ref: #{host_ref.inspect}")

      # return the host_ref
      return host_ref
    rescue Exception => error
      log(:info, error.inspect)
      return false
    end
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
    
    # set the vm_name used to reclaim from infoblox
    vm_name = vm.name rescue nil
  when 'miq_provision'
    prov = $evm.root['miq_provision'] rescue nil
    vm = prov.destination rescue nil
    ws_values = prov.get_option(:ws_values) rescue nil
    
    # set the vm_name used to reclaim from infoblox
    vm_name = prov.get_option(:vm_target_name) || prov.get_option(:vm_target_hostname) rescue nil
  else
    raise "Invalid $evm.root['vmdb_object_type']: #{$evm.root['vmdb_object_type']}"
  end
  raise 'Unable to determine VM name' if vm_name.nil?

  # set variables related to vm
  vm_name.include?('.') ? vm_fqdn = vm_name : vm_fqdn = vm_name + '.' + $evm.object['dns_domain']

  # set variables related to IPAM
  server = $evm.object['server']
  api_version = $evm.object['api_version']
  @base_url = "https://#{server}/wapi/#{api_version}/"
  @username = $evm.object['username']
  @password = $evm.object.decrypt('password')
 
  # debug logging
  if @debug == true
    log(:info, "Inspecting VM: #{vm.inspect}") unless vm.nil?
    log(:info, "Inspecting Provisioning Object: #{prov.inspect}") unless prov.nil?
  end
 
  # ====================================
  # begin main method
  # ====================================

  # log entering main method
  log(:info, "Running main portion of ruby code on method: #{@method}")

  # run methods to fetch host reference
  host_ref = fetch_host_ref(vm_fqdn)

  # remove the host if we have it, otherwise exit if we do not
  if host_ref == false
    log(:warn, "Unable to fetch host reference.  Infoblox IPAM entry for <#{vm_fqdn}> does not exist.")
    exit MIQ_OK
  else
    # remove host and return result
    result = remove_host(host_ref)
    if result ==  true
      log(:info, "Infoblox ReclaimIp --> #{vm_fqdn} reclaimed successfully")
    else
      log(:info, "Infoblox ReclaimIp --> #{vm_fqdn} FAILED")
      raise "Could not successfully reclaim host record for VM: <#{vm_fqdn}>"
    end
  end

  # ====================================
  # log end of method
  # ====================================
  
  # log exiting method and exit with MIQ_OK status
  $evm.instantiate('/System/CommonMethods/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_OK

# set ruby rescue behavior
rescue => err
  # set error message
  message = "Unable to successfully complete method: <b>#{@method}</b>.  #{err}"

  # log what we failed
  log(:warn, "#{message}")
  log(:warn, "#{err.backtrace.join("\n")}")

  # get errors variables (or create new hash)
  retire_errors = prov.get_option(:retire_errors) rescue nil
  retire_errors ||= {}
  
  # set hash with this method error
  retire_errors[:reclaim_ip_error] = message
  
  # set errors option indicating we failed reclaiming ip
  prov.set_option(:retire_errors, retire_errors) if prov

  # log exiting method and exit with something besides MIQ_OK
  $evm.instantiate('/System/CommonMethods/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_WARN
end
