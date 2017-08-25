#
# Description: Get next available IP from specified network
# Author: Dustin Scott, Red Hat
# Notes:
#  Get next IP in network based on EA filter in Infoblox (must match both key/value specified below):
#    - search_by_ea: Can search via Extensible attributes in Infoblox if needed.  Requires object_type variable
#    - object_type: Valid values are network/range.  This will add a system to the proper network/range that matches
#    the inputted extensible attributes.
#    - object_ea_key: the key to search on.  E.g. Network Environment = Dev (Key = Network Environment)
#    - object_ea_value: the value to search on.  E.g. Network Environment = Dev (Value = Dev)
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
      url = "#{@base_url}" + "#{ref}" + '?_return_fields='
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

  # parse the response and return hash
  def parse_json_response(response)
    log(:info, "Running parse_json_response...")

    # return the response if it is already a hash
    return response if response.is_a?(Hash)

    # attempt to convert the response into a hash
    response_hash = JSON.parse(response) rescue nil

    # if we do not have a hash yet, call infoblox to get the object
    if response_hash.nil?
      json_response = call_infoblox(:get, response.split("\"")[1], :json, :json)
      response_hash = JSON.parse(json_response) rescue nil
    end

    # raise an exception if we fail to convert response into hash
    raise "Unable to convert response #{response} into hash" if response_hash.nil?

    # log return the hash
    log(:info, "Inspecting response_hash: #{response_hash.inspect}")
    return response_hash
  end

  # reserve ip in network with host record
  def reserve_ip(hostname, network, dns_view, aliases = nil, start_ip = nil, end_ip = nil)
    begin
      log(:info, "Running reserve_ip...")

      # set function call based on network or range
      if network.nil?
        raise "start_ip parameter not found for range" if start_ip.nil?
        raise "end_ip parameter not found for range" if end_ip.nil?
        function_call = "func:nextavailableip:#{start_ip}-#{end_ip}"
      else
        function_call = "func:nextavailableip:#{network}"
      end

      # set body for connection
      body = {
        :ipv4addrs => [
          :ipv4addr => function_call
        ],
        :name => hostname,
        :view => dns_view,
        :configure_for_dns => true,
        :comment => "Added by CFME"
      }

      # add aliases if we have them
      body[:aliases] = aliases unless aliases.nil?

      # call infoblox to reserve ip
      host_response = call_infoblox(:post, 'record:host', :json, :json, body, 'ipv4addr')
      log(:info, "Inspecting host: #{host_response.inspect}")

      # pull the ip from the host object
      host_hash = parse_json_response(host_response)
      ip_addr = host_hash['ipv4addrs'].first['ipv4addr']
    rescue Exception => error
      log(:info, error.inspect)
      return false
    end
  end

  # finds a set of infoblox objects using extensible attribute filters and returns the object hash
  def find_objects_by_ea(ea_filter_key, ea_filter_value, object_type)
    begin
      log(:info, "Running find_objects_by_ea...")

      # set body for connection
      body = { ea_filter_key => ea_filter_value }

      # call infoblox to find object
      object_response = call_infoblox(:get, object_type, :json, :json, body)
      log(:info, "Inspecting object_response: #{object_response.inspect}")

      # convert and return the object hash
      object_hash = parse_json_response(object_response)
    rescue Exception => error
      log(:info, error.inspect)
      return false
    end
  end

  # set options on provisioning object
  def set_prov(prov, hostname, ipaddr, net_mask, gateway, dns_domain, portgroup)
    log(:info, "Running set_prov...")
    log(:info, "GetIP --> Hostname = #{hostname}")
    log(:info, "GetIP --> IP Address =  #{ipaddr}")
    log(:info, "GetIP --> Netmask = #{net_mask}")
    log(:info, "GetIP --> Gateway = #{gateway}")
    log(:info, "GetIP --> DNS Domain = #{dns_domain}")
    log(:info, "GetIP --> Portgroup = #{portgroup}")
    prov.set_option(:sysprep_spec_override, 'true')
    prov.set_option(:addr_mode, ["static", "Static"])
    prov.set_option(:ip_addr, "#{ipaddr}")
    prov.set_option(:subnet_mask, "#{net_mask}")
    prov.set_option(:gateway, "#{gateway}")
    prov.set_option(:dnsdomain, "#{dns_domain}")
    prov.set_option(:vm_target_name, "#{hostname}.#{dns_domain}")
    prov.set_option(:linux_host_name, "#{hostname}.#{dns_domain}")
    prov.set_option(:vm_target_hostname, "#{hostname}")
    prov.set_option(:host_name, "#{hostname}.#{dns_domain}")
    prov.set_option(:hostname, "#{hostname}.#{dns_domain}")
    prov.set_network_adapter(0, {:network => portgroup, :is_dvs => true}) rescue nil
    log(:info, "vm_target_name: #{prov.get_option(:vm_target_name)}") if @debug == true
    log(:info, "linux_host_name: #{prov.get_option(:linux_host_name)}") if @debug == true
    log(:info, "vm_target_hostname: #{prov.get_option(:vm_target_hostname)}") if @debug == true
    log(:info, "host_name: #{prov.get_option(:host_name)}") if @debug == true
    log(:info, "vm_name: #{prov.get_option(:vm_name)}")if @debug == true
    log(:info, "hostname: #{prov.get_option(:hostname)}")if @debug == true
    log(:info, "Inspecting provisioning object: #{prov.inspect}") if @debug == true
  end

  # ====================================
  # log beginning of method
  # ====================================

  # set method variables
  @method = $evm.current_method
  @org = $evm.root['tenant'].name rescue nil
  @debug = false

  # log entering method and dump root/object attributes
  $evm.instantiate('/Common/Log/LogBookend' + '?' + { :bookend_status => :enter, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
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
      ws_values = prov.get_option(:ws_values) rescue nil
      tags = prov.get_tags rescue nil
    else
      raise "Invalid $evm.root['vmdb_object_type']: #{$evm.root['vmdb_object_type']}"
  end

  # set variables related to network and create hash with network_vars
  network_vars = {}
  net_id = $evm.object['net_id']; network_vars[:net_id] = net_id
  net_mask = $evm.object['net_mask']; network_vars[:net_mask] = net_mask
  net_cidr = $evm.object['net_cidr']; network_vars[:net_cidr] = net_cidr
  gateway = $evm.object['gateway']; network_vars[:gateway] = gateway
  network = "#{net_id}/#{net_cidr}"; network_vars[:network] = network
  dns_domain = $evm.object['dns_domain']; network_vars[:dns_domain] = dns_domain
  dns_view = $evm.object['dns_view']; network_vars[:dns_view] = dns_view
  portgroup = $evm.object['portgroup']; network_vars[:portgroup] = portgroup

  # set vm variables
  vm_name = prov.get_option(:vm_target_name)
  vm_fqdn = vm_name + '.' + dns_domain
  aliases = ws_values[:aliases] || ws_values[:dialog_option_0_aliases] || ws_values[:option_0_aliases] rescue nil
  raise "Unable to determine vm_name to properly acquire IP address" if vm_name.nil?

  # set variables related to IPAM connection
  # NOTE: try to grab environment specific values first but fallback to default values (pulled in via object collect statement) if we don't have them
  server = $evm.object['server']
  api_version = $evm.object['api_version']
  search_by_ea = $evm.object['search_by_ea']
  object_ea_key = $evm.object['object_ea_key']
  object_ea_value = $evm.object['object_ea_value']
  object_type = $evm.object['object_type']
  @username = $evm.object['username']
  @password = $evm.object.decrypt('password')
  @base_url = "https://#{server}/wapi/#{api_version}/"

  # debug logging
  if @debug == true
    log(:info, "Inspecting VM: #{vm.inspect}") unless vm.nil?
    log(:info, "Inspecting Provisioning Object: #{prov.inspect}") unless prov.nil?
    log(:info, "Inspecting network_vars hash: #{network_vars.inspect}") unless network_vars.nil?
  end

  # ====================================
  # begin main method
  # ====================================

  # log entering main method
  log(:info, "Running main portion of ruby code on method: #{@method}")

  # get an ip based on object_type
  log( :info, "search_by_ea: #{search_by_ea}")
  if (search_by_ea == "true" || search_by_ea == true)
    # find object by ea based on our object_type if search_by_ea attribute is true
    raise "Invalid object type <#{object_type}>.  Valid values are network or range." unless (object_type == 'network' || object_type == 'range')
    object_response = find_objects_by_ea("\*#{object_ea_key}", object_ea_value, object_type)
    raise "Invalid object_response" if object_response == false
    log(:info, "Inspecting object_response for object <#{object_type}>: #{object_response.inspect}")

    # determine ip address based on our object type
    if object_type == 'network'
      object_response.each do |network|
        log(:info, "Inspecting network: #{network.inspect}")

        # find and reserve the next ip in the network we have found
        @ip_addr = reserve_ip(vm_fqdn, network['network'], dns_view, aliases)
        break unless @ip_addr == false
      end
    elsif object_type == 'range'
      object_response.each do |range|
        log(:info, "Inspecting range: #{range.inspect}")

        # find and reserve the next ip in the range we have found
        @ip_addr = reserve_ip(vm_fqdn, nil, dns_view, aliases, range['start_ip'], range['end_ip'])
        break unless @ip_addr == false
      end
    else
      @ip_addr = false
    end
  elsif (search_by_ea == "false" || search_by_ea == false)
     raise "Network ID is missing.  Cannot determine network" if net_id.nil?
     @ip_addr = reserve_ip(vm_fqdn, network, dns_view, aliases)
  else
     raise "Invalid search_by_ea parameter.  Cannot perform Infoblox search"
  end

  # set prov options
  unless @ip_addr == false
    log(:info, "GetIP --> VM #{vm_name}.#{dns_domain} with IP Address #{@ip_addr} created successfully")
    set_prov(prov, vm_name, @ip_addr, net_mask, gateway, dns_domain, portgroup)
  else
    log(:info, "GetIP --> VM #{vm_name}.#{dns_domain} with IP Address #{@ip_addr} FAILED")
    raise "Could not successfully create host record for VM: <#{vm_name}>"
  end

  # ====================================
  # log end of method
  # ====================================

  # log exiting method and exit with MIQ_OK status
  $evm.instantiate('/Common/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_OK

# set ruby rescue behavior
rescue => err
  # set error message
  message = "Unable to successfully complete method: <b>#{@method}</b>.  Could not successfully acquire IP address for VM #{vm_name}."

  # log what we failed
  log(:error, message)
  log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")

  # get errors variables (or create new hash) and set message
  errors = prov.get_option(:errors) rescue nil
  errors ||= {}

  # set hash with this method error
  errors[:acquire_ip_error] = message

  # set errors option
  prov.set_option(:errors, errors) if prov

  # log exiting method and exit with MIQ_ABORT status
  $evm.instantiate('/Common/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_ABORT
end 
