#
# Description:   Unregister client from Satellite6 Server
# Author:        Dustin Scott, Red Hat
# Creation Date: 4-Jan-2017
# Requirements:
#  - Network connectivity must be present
#  - Firewall with ports 80/443 open between CloudForms workers and Satellite Server/Capsule
#  - Valid API user/password with ability to delete hosts/content hosts
#

# ====================================
# set gem requirements
# ====================================

require 'rest-client'
require 'json'

# ====================================
# set global method variables
# ====================================

# set method variables
@method = $evm.current_method
@org    = $evm.root['tenant'].name
@debug  = $evm.root['debug'] || true

# set method constants
GET_SUCCESS_CODE    = 200
DELETE_SUCCESS_CODE = 200
HOSTS_API_ENDPOINT  = 'hosts'

# ====================================
# define methods
# ====================================

# define log method
def log(level, msg)
  $evm.log(level,"#{@org} Automation: #{msg}")
end

# create method for calling satellite server
def call_satellite(action, url, user, password, ref, content_type, body = nil)
  begin
    # change url based on if we have a ref or not
    if ref.nil?
      url = url
    else
      url = url + "/" + ref
    end

    # set params for api call
    params = {
      :method     => action,
      :url        => url,
      :user       => user,
      :password   => password,
      :verify_ssl => false,
      :headers    => { :content_type => content_type, :accept => content_type }
    }

    # generate payload data
    content_type == :json ? (params[:payload] = JSON.generate(body) if body) : (params[:payload] = body if body)
    log(:info, "Satellite6 Request: #{url} action: #{action} payload: #{params[:payload]}")

    # execute the request
    RestClient::Request.new(params).execute
  rescue => err
    # log and backtrace the error
    log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")
    log(:error, "call_satellite: #{err}.  Returning nil.")
    return nil
  end
end

# find system in satellite by its hostname
def find_system_by_hostname(system_name, url, user, password)
  begin
    # get response and convert to json
    response = call_satellite(:get, url, user, password, HOSTS_API_ENDPOINT, :json, { :search =>  system_name } )

    # validate response and return system object
    if response
      if response.code == GET_SUCCESS_CODE
        results = JSON.parse(response)['results']
        log(:info, "Inspecting results: #{results.inspect}") if @debug

        # validate the system results against the system_name
        validated_system = results.select { |result|
          if system_name.include?('.')
            result['name'].downcase == system_name.downcase
          else
            result['name'].downcase.start_with?(system_name.downcase)
          end
        }

        # ensure that we only have one system
        if validated_system.length > 1
          raise "Multiple systems with name: <#{system_name}> found.  Unable to reliably determine which system to delete"
        elsif validated_system.empty?
          return {}
        else
          log(:info, "Found system: #{validated_system}")
          return validated_system.first
        end
      else
        raise "Invalid Response code #{response.code}"
      end
    else
      raise "Invalid Response: #{response.inspect}"
    end
  rescue => err
    # log and backtrace the error
    log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")
    log(:error, "find_system_by_hostname: #{err}.  Returning false")
    return false
  end
end

# delete system from satellite
def delete_system(system, url, user, password)
  begin
    # tell the call to use a system/uuid as a ref
    ref = HOSTS_API_ENDPOINT + "/" + system['id'].to_s
    log(:info, "Using ref: <#{ref}> to delete system from Satellite.")

    # get response and convert to json
    response = call_satellite(:delete, url, user, password, ref, :json)

    # validate response and return system object
    if response
      if response.code == DELETE_SUCCESS_CODE
        log(:info, "delete_system: Successfully deleted system: #{system.inspect}")
        return JSON.parse(response)
      else
        raise "Invalid Response code #{response.code}"
      end
    else
      raise "Invalid Response: #{response.inspect}"
    end
  rescue => err
    # log and backtrace the error
    log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")
    log(:error, "delete_system: #{err}.  Returning false")
    return false
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

  if prov && vm
    log(:info, "Inspecting provisioning object: #{prov.inspect}") if @debug
    log(:info, "Inspecting VM object: #{vm.inspect}") if @debug

    # set satellite variables
    sat_unregister_attrs = {
      :sat_api_url      => $evm.object['sat_api_url'],
      :sat_api_user     => $evm.object['sat_api_user'],
      :sat_api_password => $evm.object.decrypt('sat_api_password')
    }

    # validate that we successfully pulled all require variables to continue
    sat_unregister_attrs.each do |k,v|
      log(:info, "sat_unregister_attrs: Key: <#{k}>, Value: <#{v}>")
      raise "Missing value for Key: <#{k}>" if v.nil?
    end

    # run methods to unregister system from satellite
    # NOTE: try and grab the FQDN first and fail back to the name of the VM next
    vm_name = vm.hostnames.first || vm.name
    log(:info, "Searching Satellite VM record : <#{vm_name}>")
    system = find_system_by_hostname(vm_name, sat_unregister_attrs[:sat_api_url], sat_unregister_attrs[:sat_api_user], sat_unregister_attrs[:sat_api_password])

    if system.nil?
      log(:warn, "Satellite system record not found for <#{vm_name}>.  Skipping.")
    elsif system.empty?
      log(:warn, "Unable to find system with name: <#{vm_name}>.  Was this system deleted manually?")
    elsif system == false
      raise "Error finding system with name: <#{vm_name}>"
    else
      log(:info, "Inspecting system: #{system.inspect}") if @debug
      log(:info, "Unsubscribing #{system['name']} : #{system['id']}")
      delete_response = delete_system(system, sat_unregister_attrs[:sat_api_url], sat_unregister_attrs[:sat_api_user], sat_unregister_attrs[:sat_api_password])
      log(:info, "Inspecting delete_response: #{delete_response.inspect}") if @debug
    end
  else
    raise "Unable to find provisioning object or VM"
  end

  # ====================================
  # exit method
  # ====================================

  if delete_response == false
    raise "Error deleting system: <#{vm_name}> from Satellite"
  else
    exit MIQ_OK
  end

# set ruby rescue behavior
rescue => err
  # set error message
  message = "Unable to successfully complete method: <b>#{@method}</b>.  Error: #{err}"

  # log what we failed
  log(:error, message)
  log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")

  # get errors variables (or create new hash) and set message
  if prov
    errors                                     = prov.get_option(:errors)
    errors[:satellite_unregister_client_error] = message
    prov.set_option(:errors, errors)
  end

  # exit with something other than MIQ_OK status
  exit MIQ_ABORT
end
