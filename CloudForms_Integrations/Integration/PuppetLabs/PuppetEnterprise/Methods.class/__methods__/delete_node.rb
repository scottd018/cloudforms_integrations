#
# Description:   Delete node from PuppetDB
# Author:        Dustin Scott, Red Hat
# Creation Date: 17-Jan-2017
# Requirements:
#  - Network connectivity must be present
#  - Firewall with ports 8081 open between CloudForms workers and Puppet Server
#  - A generic certificate must be used for authentication.  This certificate will be pulled from the variables domain.  The
#    generic certificate can be generated on the Puppet CA server as follows:
#
#      puppet cert generate generic.mydomain.net
#
#    The following files from the Puppet CA server should be used after generating the certificate above and
#    placed in the Variables domain (encrypted - use Password as attribute type):
#
#      puppet_auth_cert = /etc/puppetlabs/puppet/ssl/ca/signed/generic.mydomain.net.pem
#      puppet_auth_key  = /etc/puppetlabs/puppet/ssl/private_keys/generic.mydomain.net.pem
#
# NOTE: Certificate should have each newline replaced with a ':' (colon) character.  When this certificate gets pulled in,
# the colon is replaced with a new line character (\n).  This is because the certificate cannot be stored as an object,
# and thus has to be manipulated to be used correctly.
#
# After successful creation of the generic certificate, used for API endpoint authentication, the certificate FQDN must be
# placed in the following file:
#
#   - /etc/puppetlabs/puppetdb/certificate-whitelist
#

# ====================================
# set gem requirements
# ====================================

require 'rest-client'
require 'json'
require 'openssl'

# ====================================
# set global method variables
# ====================================

# set method variables
@method = $evm.current_method
@org    = $evm.root['tenant'].name
@debug  = $evm.root['debug'] || false

# set method constants
GET_NODE_SUCCESS_CODE       = 200
DELETE_NODE_SUCCESS_CODE    = 200
DELETE_NODE_COMMAND         = 'deactivate node'
DELETE_NODE_COMMAND_VERSION = 3

# ====================================
# define methods
# ====================================

# define log method
def log(level, msg)
  $evm.log(level,"#{@org} Automation: #{msg}")
end

# create method for making a rest call
def call_rest(action, url, auth_cert, auth_key, ref, content_type, body = nil)
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
      :ssl_client_cert => OpenSSL::X509::Certificate.new(auth_cert),
      :ssl_client_key  => OpenSSL::PKey::RSA.new(auth_key),
      :verify_ssl      => false,
      :headers         => { :content_type => content_type, :accept => content_type }
    }

    # generate payload data
    content_type == :json ? (params[:payload] = JSON.generate(body) if body) : (params[:payload] = body if body)
    log(:info, "call_rest: Request: #{url} action: #{action} payload: #{params[:payload]}")

    # execute the request
    RestClient::Request.new(params).execute
  rescue => err
    # log and backtrace the error
    log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")
    log(:error, "call_rest: #{err}.  Returning nil.")
    return nil
  end
end

# delete node from puppetdb
def delete_node(fqdn, url, auth_cert, auth_key)
  begin
    # set the payload
    payload = {
      :command  => DELETE_NODE_COMMAND,
      :version  => DELETE_NODE_COMMAND_VERSION,
      :payload  => {
        :certname => fqdn
      }
    }

    # get response and convert to json
    response = call_rest(:post, url, auth_cert, auth_key, nil, :json, payload)

    # validate response and return system object
    if response
      log(:info, "delete_node: Inspecting response: #{response.inspect}") if @debug
      log(:info, "delete_node: Inspecting response body: #{response.body.inspect}") if @debug
      if response.code == DELETE_NODE_SUCCESS_CODE
        log(:info, "delete_node: Successfully deleted node from PuppetDB for system: #{fqdn}")
        return true
      else
        raise "Invalid Response code #{response.code}"
      end
    else
      raise "Invalid Response: #{response.inspect}"
    end
  rescue => err
    # log and backtrace the error
    log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")
    log(:error, "delete_node: #{err}.  Returning false")
    return false
  end
end

# get node object from puppetdb
def get_node(fqdn, url, auth_cert, auth_key)
  begin
    # tell the call to use a system/uuid as a ref
    ref = "nodes"
    log(:info, "get_node: Using ref: <#{ref}> to get PuppetDB Node.")

    # get response and convert to json
    response = call_rest(:get, url, auth_cert, auth_key, ref, :json, nil)

    # validate response and return system object
    if response
      log(:info, "get_node: Inspecting response: #{response.inspect}") if @debug
      log(:info, "get_node: Inspecting response body: #{response.body.inspect}") if @debug

      if response.code == GET_NODE_SUCCESS_CODE
        log(:info, "get_node: Successfully retrieved nodes from PuppetDB for system: #{fqdn}")
        nodes = JSON.parse(response.body)
        log(:info, "get_node: Inspecting nodes: #{nodes.inspect}") if @debug

        # get the node and return it
        node = nodes.select { |n| n['certname'] == fqdn }
      else
        log(:warn, "get_node: Unable to retrieve node object from PuppetDB for system: #{fqdn}.  Returning empty array.")
        return []
      end
    else
      raise "Invalid Response: #{response.inspect}"
    end
  rescue => err
    # log and backtrace the error
    log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")
    log(:error, "get_node: #{err}.  Returning nil.")
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
    vm_name = vm.name.downcase
    domain  = prov.get_option(:dnsdomain) || prov.get_option(:dns_domain)
    if domain
      fqdn = "#{vm_name}.#{domain}"
    else
      raise "Missing domain via: prov.get_option(:dnsdomain) || prov.get_option(:dns_domain)"
    end
    log(:info, "VM FQDN: <#{fqdn}>")

    # set puppet variables
    puppet_delete_node_attrs = {
      :puppet_db_query_api_url => $evm.object['puppet_db_query_api_url'],
      :puppet_db_cmd_api_url   => $evm.object['puppet_db_cmd_api_url'],
      :puppet_auth_cert        => $evm.object.decrypt('puppet_auth_cert'),
      :puppet_auth_key         => $evm.object.decrypt('puppet_auth_key')
    }

    # validate that we successfully pulled all require variables to continue
    puppet_delete_node_attrs.each do |k,v|
      log(:info, "puppet_delete_node_attrs: Key: <#{k}>, Value: <#{v}>")
      raise "Missing value for Key: <#{k}>" if v.nil?
    end

    # get the node object to validate that it exists in the PuppetDB
    node = get_node(
      fqdn,
      puppet_delete_node_attrs[:puppet_db_query_api_url],
      puppet_delete_node_attrs[:puppet_auth_cert].gsub(/:/, "\n"),  # NOTE: we are replacing : chars with newlines
      puppet_delete_node_attrs[:puppet_auth_key].gsub(/:/, "\n")    # NOTE: we are replacing : chars with newlines
    )
    log(:info, "Inspecting node: #{node.inspect}")

    # # delete the node if we found it, otherwise warn and exit
    if node.empty?
      log(:warn, "Unable to find node: <#{fqdn}> in PuppetDB.  Was this manually deleted?")
      exit MIQ_WARN
    elsif node.nil?
      raise "Error attempting to get node: <#{fqdn}> from PuppetDB."
    else
      log(:info, "Deleting node: <#{fqdn}> from PuppetDB")
      delete_results = delete_node(
        fqdn,
        puppet_delete_node_attrs[:puppet_db_cmd_api_url],
        puppet_delete_node_attrs[:puppet_auth_cert].gsub(/:/, "\n"),  # NOTE: we are replacing : chars with newlines
        puppet_delete_node_attrs[:puppet_auth_key].gsub(/:/, "\n")    # NOTE: we are replacing : chars with newlines
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
    raise "Error deleting Puppet Node: <#{fqdn}> from PuppetDB"
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
    errors                            = prov.get_option(:errors)
    errors[:puppet_delete_node_error] = message
    prov.set_option(:errors, errors)
  end

  # exit with something other than MIQ_OK status
  exit MIQ_ABORT
end
