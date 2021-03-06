#
# Description:   Sign Puppet Enterprise Certificate
# Author:        Dustin Scott, Red Hat
# Creation Date: 16-Jan-2017
# Requirements:
#  - Network connectivity must be present
#  - Firewall with ports 8140 open between CloudForms workers and Puppet CA Server
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
#  - The following lines need to be added to the /etc/puppetlabs/puppetserver/conf.d/auth.conf file
#    (add above the 'puppetlabs certificate status' rule):
#
#      {
#        "allow" : [
#        "pemaster-01.mydomain.net",            # this is the puppet ca server fqdn
#        "generic.mydomain.net"                 # this is the fqdn of the generic certificate that was generated
#      ],
#        "match-request" : {
#        "method" : [
#        "get",
#        "put",
#        "delete"
#      ],
#        "path" : "^/puppet-ca/v1/certificate_status/([^/]+)$"
#        "query-params" : {},
#        "type" : "regex"
#      },
#        "name" : "puppetlabs certificate node status",
#        "sort-order" : 500
#      }
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
SIGN_CERT_SUCCESS_CODE = 204

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

# sign certificate
def sign_cert(fqdn, url, auth_cert, auth_key)
  begin
    # tell the call to use a system/uuid as a ref
    ref = "certificate_status/#{fqdn}"
    log(:info, "sign_cert: Using ref: <#{ref}> to sign Puppet Enterprise Certificate.")

    # get response and convert to json
    response = call_rest(:put, url, auth_cert, auth_key, ref, :json, { "desired_state" => "signed" } )

    # validate response and return system object
    if response
      if response.code == SIGN_CERT_SUCCESS_CODE
        log(:info, "sign_cert: Successfully signed certificate for system: #{fqdn}")
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
    log(:error, "sign_cert: #{err}.  Returning false")
    return false
  end
end

# ====================================
# begin main method
# ====================================

begin
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

    # set puppet variables
    puppet_sign_cert_attrs = {
      :puppet_ca_api_url => $evm.object['puppet_ca_api_url'],
      :puppet_auth_cert  => $evm.object.decrypt('puppet_auth_cert'),
      :puppet_auth_key   => $evm.object.decrypt('puppet_auth_key')
    }

    # validate that we successfully pulled all require variables to continue
    puppet_sign_cert_attrs.each do |k,v|
      log(:info, "puppet_sign_cert_attrs: Key: <#{k}>, Value: <#{v}>")
      raise "Missing value for Key: <#{k}>" if v.nil?
    end

    # sign the vm certificate
    sign_results = sign_cert(
      fqdn.downcase,
      puppet_sign_cert_attrs[:puppet_ca_api_url],
      puppet_sign_cert_attrs[:puppet_auth_cert].gsub(/:/, "\n"),  # NOTE: we are replacing : chars with newlines
      puppet_sign_cert_attrs[:puppet_auth_key].gsub(/:/, "\n")    # NOTE: we are replacing : chars with newlines
    )
    log(:info, "Inspecting sign_results: #{sign_results.inspect}") if @debug
  else
    raise "Unable to find VM or provisioning object"
  end

  # ====================================
  # exit method
  # ====================================

  if sign_results == false
    raise "Error signing Puppet Enterprise cert: <#{fqdn}>"
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
    errors                          = prov.get_option(:errors)
    errors[:puppet_sign_cert_error] = message
    prov.set_option(:errors, errors)
  end

  # exit with something other than MIQ_OK status
  exit MIQ_ABORT
end
