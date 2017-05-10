#
# Description:   Build the activation key required to register with Satellite Server
# Author:        Dustin Scott, Red Hat
# Creation Date: 4-Jan-2017
# Last Updated:  14-Mar-2017
# Requirements:
#  - Environment option set via tag or ws_values (needed because each activation key is tied to a particular lifecycle environment)
#  - Function option set via tag or ws_values (needed because each activation key controls access to subscriptions, products, and content views)
#  - Server usage (e.g. infra vs. biz via dos_server_usage) from dialog
#  - Subscription name set on each function that is deployable
#  - Operating System short name (e.g. Red Hat Enterprise Linux 6 = RHEL6)
#  - Key prefix set in Satellite Variables
#
# Activation Key strings are built as follows:
#   - content key = <KEY_PREFIX>-<LIFECYCLE_ENVIRONMENT>-<SERVER_USAGE>-<OS_SHORT_NAME>
#       Example: act-dev-infra-rhel6  -OR-  act-prod-biz-rhel7
#   - subscription key = <KEY_PREFIX>-<SUBSCRIPTION_KEY_PREFIX>-<SUBSCRIPTION_NAME>
#       Example: act-sub-rhel7gitlab  -OR-  act-sub-rhel7satcap
#   - group key = <KEY_PREFIX>-<GROUP_KEY_PREFIX>-<GROUP_NAME>
#       Example: act-group-entops  -OR-  act-group-npe
#
# Once keys are built, they are chained together when registering with Satellite as follows:
#   - <CONTENT_KEY>,<SUBSCRIPTION_KEY>,<GROUP_KEY>
#       Example: subscription-manager register --org CST --activationkey=act-dev-infra-rhel6,act-group-entops.act-sub-gitlab
#

# ====================================
# set global method variables
# ====================================

# set method variables
@method = $evm.current_method
@org    = $evm.root['tenant'].name
@debug  = $evm.root['debug'] || false

# set method constants
OS_CLASS                  = '/Common/OperatingSystems'
ENVIRONMENT_CLASS         = '/Common/Environments'
FUNCTION_CLASS            = '/Common/Functions'
SAT_SUB_KEY_ATTR          = 'sat_sub_activation_key'
SAT_ENV_KEY_ATTR          = 'sat_env_activation_key'
SAT_KEY_PREFIX_ATTR       = 'sat_activation_key_prefix'
SAT_GROUP_KEY_PREFIX_ATTR = 'sat_group_activation_key_prefix'
SAT_SUB_KEY_PREFIX_ATTR   = 'sat_sub_activation_key_prefix'

# ====================================
# define methods
# ====================================

# define log method
def log(level, msg)
  $evm.log(level,"#{@org} Automation: #{msg}")
end

# get operating system attributes from operating system selection
def get_os_attrs(source, attr, source_type)
  begin
    # grab the product name from the template we are current provisioning from
    if source_type == 'prov'
      os_name = source.source.operating_system.product_name rescue nil
    elsif source_type == 'vm'
      os_name = source.operating_system.product_name rescue nil
    else
      raise "Invalid source_type input"
    end

    log(:info, "get_os_attrs: Returning Operating System attribute <#{attr}> for Operating System <#{os_name}>")
    # first we must truncate the product name in a camel case format
    # e.g. Red Hat Enterprise Linux 6 = RedHatEnterpriseLinux6
    truncated_product_name = os_name.split('(').first.delete(' ')

    # return the requested attribute
    $evm.instantiate("#{OS_CLASS}/#{truncated_product_name}")[attr]
  rescue => err
    log(:error, "get_os_attrs: <#{err}>: Unable to return proper attribute <#{attr}> from os_name <#{os_name}>.  Returning nil.")
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

    # get options_hash from tags or ws_values
    options_hash   = prov.get_option(:ws_values)
    options_hash ||= prov.get_tags

    # get necessary values from options_hash
    if options_hash
      log(:info, "Inspecting options_hash: #{options_hash.inspect}")
      key_attrs = {
        :environment      => options_hash[:dos_environment],
        :group            => options_hash[:dos_group],
        :server_usage     => options_hash[:dos_server_usage],
        :function         => options_hash[:dos_function],
        :os_short_name    => get_os_attrs(prov, 'short_name', 'prov'),
        :group_key_prefix => $evm.object[SAT_GROUP_KEY_PREFIX_ATTR],
        :sub_key_prefix   => $evm.object[SAT_SUB_KEY_PREFIX_ATTR],
        :key_prefix       => $evm.object[SAT_KEY_PREFIX_ATTR]
      }

      # validate that we successfully pulled all require variables to continue
      key_attrs.each do |k,v|
        log(:info, "key_attrs: Key: <#{k}>, Value: <#{v}>")
        raise "Missing value for Key: <#{k}>" if v.nil?
      end

      # get the satellite subscription > function and environment > lifecycle environment mappings
      subscription_key_value = $evm.instantiate("#{FUNCTION_CLASS}/#{key_attrs[:function]}")[SAT_SUB_KEY_ATTR]
      environment_key_value  = $evm.instantiate("#{ENVIRONMENT_CLASS}/#{key_attrs[:environment]}")[SAT_ENV_KEY_ATTR]
      
      # build the activation key strings
      strings_hash = {
        :content_key_string => [ key_attrs[:key_prefix], environment_key_value, key_attrs[:server_usage], key_attrs[:os_short_name] ].join('-'),
        :group_key_string   => [ key_attrs[:key_prefix], key_attrs[:group_key_prefix], key_attrs[:group] ].join('-'),
        :sub_key_string     => [ key_attrs[:key_prefix], key_attrs[:sub_key_prefix], "#{key_attrs[:os_short_name]}#{subscription_key_value}" ].join('-')
      }

      # combine key_string with group_key_string
      log(:info, "Generating key_string from strings_hash: #{strings_hash.inspect}")
      key_string = [ strings_hash[:content_key_string], strings_hash[:group_key_string], strings_hash[:sub_key_string] ].join(',')

      # log and set the key_string on root
      log(:info, "Setting key_string: <#{key_string}> on $evm.root as variable: <activation_key>")
      $evm.root['activation_key'] = key_string
    else
      raise "Unable to find options_hash via ws_values or tags"
    end
  else
    raise "Unable to find provisioning object or VM"
  end

  # ====================================
  # exit method
  # ====================================

  exit MIQ_OK

# set ruby rescue behavior
rescue => err
  # set error message
  message = "Unable to successfully complete method: <b>#{@method}</b>.  Error: #{err}"

  # log what we failed
  log(:error, message)
  log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")

  # get errors variables (or create new hash) and set message
  if prov
    errors                                        = prov.get_option(:errors)
    errors[:satellite_build_activation_key_error] = message
    prov.set_option(:errors, errors)
  end

  # exit with something other than MIQ_OK status
  exit MIQ_ABORT
end
