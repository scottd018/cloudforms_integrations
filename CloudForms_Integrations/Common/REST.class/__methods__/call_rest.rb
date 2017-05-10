#
# Description: Makes a REST Call
#
# Input Requirements:
#  - rest_action:       HTTP actions (GET, POST, PUT, DELETE)
#  - rest_base_url:     base URL without the resource
#  - rest_resource:     the resource to perform the action on
#  - rest_api_user:     the api user to perform the REST call
#  - rest_api_password: the password of the api user making the REST call
#
# Other Inputs (Optional):
#  - rest_debug:        configures debug logging behavior (Defaults to false)
#  - rest_auth_type:    authentication type for REST (Defaults to Basic, which is the only supported method as of now)
#  - rest_content_type: valid values are XML or JSON (defaults to JSON)
#  - rest_return_type:  valid values are XML or JSON (defaults to JSON)
#  - rest_verify_ssl:   tells the rest call to verify the SSL connection or ignore (defaults to true)
#  - rest_payload:      the payload data to use when executing the REST call (must be in rest_content_type format - defaults to 'default')
#    NOTE: rest_payload must be passed in as a string due to inability in this version (4.1) to pass objects as inputs
#
# Notes:
#  - XML is currently untested
# 
# Usage:
#   - Can be called as follows:
#
# rest_instance_path = "/System/CommonMethods/REST/CallRest"
# rest_query = {
#   :rest_action       => :get,
#   :rest_base_url     => 'https://resturl.example.com/api',
#   :rest_resource     => :resource_for_rest_call,
#   :rest_api_user     => 'admin',
#   :rest_api_password => 'admin',
#   :rest_verify_ssl   => false,
#   :rest_debug        => true
# }.to_query
# $evm.instantiate(rest_instance_path + '?' + rest_query)
#
# Return Values (set on the $evm.root):
#   - rest_status:  returns true on success, false on failure
#   - rest_results: returns the results of the REST call (in an array format; can be converted to a hash)
#
# Author:     Dustin Scott, Red Hat
# Created On: June 22, 2016
#

begin
  # ====================================
  # set gem requirements
  # ====================================

  require 'rest-client'
  require 'json'
  require 'nokogiri'
  require 'base64'

  # ====================================
  # set global method variables
  # ====================================

  # set method variables
  @method = $evm.current_method
  @org    = $evm.root['tenant'].name
  @debug  = $evm.inputs['rest_debug'] || false

  # set method constants
  VALID_REST_ACTIONS       = [ 'get', 'post', 'put', 'delete' ].freeze
  VALID_REST_AUTH_TYPES    = [ 'basic' ].freeze
  VALID_REST_CONTENT_TYPES = [ 'xml', 'json' ].freeze
  VALID_REST_RETURN_TYPES  = [ 'xml', 'json' ].freeze

  # log entering method
  log(:info, "Entering sub-method <#{@method}>")

  # ====================================
  # define methods
  # ====================================

  # define log method
  def log(level, msg)
    $evm.log(level,"#{@org} Automation: #{msg}")
  end

  # parse the response and return hash
  def parse_response(response, return_type)
    log(:info, "Running parse_response...")

    # return the response if it is already a hash
    if response.is_a?(Hash)
      log(:info, "Response <#{response.inspect}> is already a hash.  Returning response.")
      return response
    else
      if return_type == 'json'
        # attempt to convert the JSON response into a hash
        log(:info, "Response type requested is JSON.  Converting JSON response to hash.")
        response_hash = JSON.parse(response) rescue nil
      elsif return_type == 'xml'
        # attempt to convert the XML response into a hash
        log(:info, "Response type requested is XML.  Converting XML response to hash.")
        response_hash = Hash.from_xml(response) rescue nil
      else
        # the return_type we have specified is invalid
        raise "Invalid return_type <#{return_type}> specified"
      end
    end

    # raise an exception if we fail to convert response into hash
    raise "Unable to convert response #{response} into hash" if response_hash.nil?

    # log return the hash
    log(:info, "Inspecting response_hash: #{response_hash.inspect}") if @debug == true
    log(:info, "Finished running parse_response...")
    return response_hash
  end

  # executes the rest call with parameters
  def execute_rest(rest_url, params, return_type)
    log(:info, "Running execute_rest...")

    # log the parameters we are using for the rest call
    log(:info, "Inspecting REST params: #{params.inspect}") if @debug == true

    # execute the rest call
    rest_response = RestClient::Request.new(params).execute

    # convert the rest_response into a usable hash
    rest_hash = parse_response(rest_response, return_type)
    log(:info, "Finished running execute_rest...")
    return rest_hash
  end

  # ====================================
  # set variables
  # ====================================

  # log setting variables
  log(:info, "Setting variables for sub-method: <#{@method}>")

  # set inputs variables with all inputs
  inputs = {
    :rest_action       => $evm.inputs['rest_action'],
    :rest_base_url     => $evm.inputs['rest_base_url'],
    :rest_resource     => $evm.inputs['rest_resource'],
    :rest_api_user     => $evm.inputs['rest_api_user'],
    :rest_api_password => $evm.inputs['rest_api_password'],
    :rest_auth_type    => $evm.inputs['rest_auth_type'],
    :rest_content_type => $evm.inputs['rest_content_type'],
    :rest_return_type  => $evm.inputs['rest_return_type'],
    :rest_verify_ssl   => $evm.inputs['rest_verify_ssl'],
    :rest_payload      => $evm.inputs['rest_payload']
  }

  # dynamically set variable strings to pull later based on our object type
  case $evm.root['vmdb_object_type']
    when 'vm'
      # get variables for vm object
    when 'miq_provision'
      # get variables for provision object
    when 'service_template_provision_task'
      # get variables for service template object
    else
      # get variables for unknown vmdb_object_type
  end

  # ====================================
  # validate variables
  # ====================================

  # log validating variables
  log(:info, "Validating variables for sub-method: <#{@method}>")

  # make sure we have no nil inputs that are required
  inputs.each { | k, v| raise "Unable to determine required input <#{k}>" if v.nil? }

  # create a hash of validation steps and loop through them to make sure everything is ok
  validate_hash = {
    inputs[:rest_action]       => VALID_REST_ACTIONS,
    inputs[:rest_auth_type]    => VALID_REST_AUTH_TYPES,
    inputs[:rest_content_type] => VALID_REST_CONTENT_TYPES,
    inputs[:rest_return_type]  => VALID_REST_RETURN_TYPES
  }

  # validate the hash
  validate_hash.each do | input_value, valid_values |
    # log the hash
    log(:info, "Validating hash input value: <#{input_value}>, valid values: #{valid_values.inspect}") if @debug == true

    # make sure our values match what we consider to be valid
    unless valid_values.values.include?(input_value)
      raise "Invalid <#{valid_values.keys.first}> input.  Valid values are: #{valid_values.values.first.inspect}"
    end
  end

  # ====================================
  # begin main method
  # ====================================

  # log entering main method
  log(:info, "Running main portion of ruby code on sub-method: <#{@method}>")

  # set rest url
  rest_url = inputs[:rest_base_url] + '/' + inputs[:rest_resource]
  log(:info, "Used rest_base_url: <#{inputs[:rest_base_url]}>, and rest_resource: <#{inputs[:rest_resource]}>, to generate rest_url: <#{rest_url}>")

  # set params for api call
  params = {
    :method     => inputs[:rest_action],
    :url        => rest_url,
    :verify_ssl => inputs[:rest_verify_ssl],
    :headers    => {
      :content_type => inputs[:rest_content_type],
      :accept       => inputs[:rest_return_type]
    }
  }

  # set the authorization header based on the type requested
  if inputs[:rest_auth_type] == 'basic'
    params[:headers][:authorization] = "Basic #{Base64.strict_encode64("#{inputs[:rest_api_user]}:#{inputs[:rest_api_password]}")}"
  else
    #
    # code for extra rest_auth_types goes here. currently only supports basic authentication
    #
  end

  # generate payload data
  if inputs[:rest_content_type].to_s == 'json'
    # generate our body in JSON format
    params[:payload] = JSON.generate(inputs[:rest_payload]) unless inputs[:rest_payload].first == 'default'
  else
    # generate our body in XML format
    params[:payload] = Nokogiri::XML(inputs[:rest_payload]) unless inputs[:rest_payload].first == 'default'
  end

  # get the rest_response and set it on the root object
  rest_results = execute_rest(rest_url, params, inputs[:rest_return_type])
  $evm.root['rest_results'] = rest_results unless rest_results.nil?

  # ====================================
  # log end of method
  # ====================================

  # log exiting method and let the root object know we succeeded
  log(:info, "Exiting sub-method <#{@method}>")
  $evm.root['rest_status'] = true
  exit MIQ_OK

# set ruby rescue behavior
rescue => err
  # set error message
  message = "Error in method <#{@method}>: #{err}"

  # log what we failed
  log(:error, message)
  log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")

  # let the root object know that we failed
  $evm.root['rest_status'] = false

  # log exiting method and exit with MIQ_WARN status
  log(:info, "Exiting sub-method <#{@method}>")
  exit MIQ_WARN
end
