#
# Description:   Deletes host from Identity Management
# Author:        Dustin Scott, Red Hat
# Creation Date: 17-Jan-2017
# Requirements:
#  - Network connectivity must be present
#  - Firewall with ports 443 open between CloudForms workers and IDM Server
#  - Test on latest version of IDM as of 17-Jan-2017 (REST API is in tech preview)
#  - User with the ability to add/remove hosts and DNS records
#

# ====================================
# set gem requirements
# ====================================

require 'rest-client'
require 'json'
require 'openssl'
require 'uri'

# ====================================
# set global method variables
# ====================================

# set method variables
@method = $evm.current_method
@org    = $evm.root['tenant'].name
@debug  = $evm.root['debug'] || true

# set method constants
DELETE_HOST_SUCCESS_CODE = 200
GET_COOKIE_SUCCESS_CODE  = 200

# ====================================
# define methods
# ====================================

# define log method
def log(level, msg)
  $evm.log(level,"#{@org} Automation: #{msg}")
end

# create method for making a rest call
def call_rest(action, url, headers, ref, body = nil)
  begin
    # change url based on if we have a ref or not
    if ref.nil?
      url = url
    else
      url = url + "/" + ref
    end

    # set params for api call
    params = {
      :method          => action,
      :url             => url,
      :verify_ssl      => false,
      :headers         => headers
    }

    # generate payload data
    params[:payload] = body if body
    log(:info, "call_rest: Request URL:     #{url}")
    log(:info, "call_rest: Request Action:  #{action}")
    log(:info, "call_rest: Request Headers: #{headers.inspect}")
    log(:info, "call_rest: Request Payload: #{params[:payload]}")

    # execute the request
    RestClient::Request.new(params).execute
  rescue => err
    # log and backtrace the error
    log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")
    log(:error, "call_rest: #{err}.  Returning nil.")
    return nil
  end
end

# get cookie
def get_cookie(url, user, password)
  begin
    # set the headers
    headers = {
      :content_type => 'application/x-www-form-urlencoded',
      :accept       => 'text/plain'
    }

    # get response and convert to json
    response = call_rest(:post, url, headers, 'session/login_password', "user=#{user}&password=#{password}")

    # validate response and return system object
    if response
      log(:info, "get_cookie: Inspecting response: #{response.inspect}") if @debug
      log(:info, "get_cookie: Inspecting response body: #{response.body.inspect}") if @debug
      if response.code == GET_COOKIE_SUCCESS_CODE
        unless response.cookies.nil? || response.cookies.empty?
          cookies_hash = response.cookies
          cookies_form = URI.encode_www_form(cookies_hash)
          log(:info, "get_cookie: Successfully retrieved cookies")
          log(:info, "get_cookie:   cookies_hash: #{cookies_hash}")
          log(:info, "get_cookie:   cookies_form: #{cookies_form} < Returning")
          return cookies_form
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
    log(:error, "get_cookie: #{err}.  Returning nil")
    return nil
  end
end

# delete host from idm
def delete_host(fqdn, url, cookie)
  begin
    # set the headers
    headers = {
      :content_type => :json,
      :accept       => :json,
      'Cookie'      => cookie,
      'Referer'     => url
    }

    # set the payload
    payload = {
      :method => 'host_del',
      :params => [
        [ fqdn ],
        {
          :continue  => false,
          :updatedns => true
        }
      ]
    }

    # get response and convert to json
    response = call_rest(:post, url, headers, 'session/json', JSON.generate(payload))

    # validate response and return system object
    if response
      log(:info, "delete_host: Response body: #{response.body}") if @debug
      if response.code == DELETE_HOST_SUCCESS_CODE
        errors = JSON.parse(response.body)['error']
        log(:info, "delete_host: The following errors were logged during the previous REST call: #{errors.inspect}")

        # NOTE: success code 4001 indicate the host didn't exist
        if errors.nil? || errors['code'].to_i == 4001
          log(:info, "delete_host: Successfully deleted host object for system: #{fqdn}")
          return true
        else
          log(:warn, "delete_host: Unable to delete system: #{fqdn} from IDM")
          raise "Please review the following errors: #{errors.inspect}"
        end
      else
        log(:warn, "delete_host: Unable to retrieve node object from PuppetDB for system: #{fqdn}.  Returning false")
        return false
      end
    else
      raise "Invalid Response: #{response.inspect}"
    end
  rescue => err
    # log and backtrace the error
    log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")
    log(:error, "delete_host: #{err}.  Returning false")
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

    # get the vm fqdn
    vm_name = vm.name
    domain  = prov.get_option(:dnsdomain) || prov.get_option(:dns_domain)
    if domain
      fqdn = "#{vm_name}.#{domain}"
    else
      raise "Missing domain via: prov.get_option(:dnsdomain) || prov.get_option(:dns_domain)"
    end
    log(:info, "VM FQDN: <#{fqdn}>")

    # set idm variables
    idm_delete_host_attrs = {
      :idm_api_url  => $evm.object['idm_api_url'],
      :idm_username => $evm.object['idm_user'],
      :idm_password => $evm.object.decrypt('idm_password')
    }

    # validate that we successfully pulled all require variables to continue
    idm_delete_host_attrs.each do |k,v|
      log(:info, "idm_delete_host_attrs: Key: <#{k}>, Value: <#{v}>")
      raise "Missing value for Key: <#{k}>" if v.nil?
    end

    # get cookies for delete_host api call
    cookie = get_cookie(
      idm_delete_host_attrs[:idm_api_url],
      idm_delete_host_attrs[:idm_username],
      idm_delete_host_attrs[:idm_password]
    )

    if cookie.nil?
      raise "Unable to get cookie for delete_host API call"
    else
      # delete the host from idm
      delete_results = delete_host(
        fqdn,
        idm_delete_host_attrs[:idm_api_url],
        cookie
      )
      log(:info, "Inspecting delete_results: #{delete_results.inspect}") if @debug
    end
  else
    raise "Unable to find VM or provisioning object"
  end

  # ====================================
  # exit method
  # ====================================

  if delete_results == false
    raise "Error deleting IDM Host: <#{fqdn}> from IDM"
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
    errors                         = prov.get_option(:errors)
    errors[:idm_delete_host_error] = message
    prov.set_option(:errors, errors)
  end

  # exit with something other than MIQ_OK status
  exit MIQ_ABORT
end
