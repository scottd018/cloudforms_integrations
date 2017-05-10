#
# Description:   Gets a specific dialog value (option or tag) and sets the value on root
# an internal IPAM address.
# Author:        Dustin Scott, Red Hat
# Creation Date: 23-Jan-2017
# Requirements:
#  - Option or tag to get via $evm.inputs['dialog_key']
# Output:
#  - The value is set on $evm.root and can be pulled via:
#    var = $evm.root['dialog_key'] (where dialog key is the same key value as the dialog option)
# NOTE:
#   - Deprecation Warning: this method should be deprecated in favor of null coalescers in CloudForms 4.2
#

# ====================================
# set global method variables
# ====================================

# set method variables
@method = $evm.current_method
@org    = $evm.root['tenant'].name
@debug  = $evm.root['debug'] || false

# set method constants
DIALOG_KEY = $evm.inputs['dialog_key']

# ====================================
# define methods
# ====================================

# define log method
def log(level, msg)
  $evm.log(level,"#{@org} Automation: #{msg}")
end

# ====================================
# begin main method
# ====================================

begin
  # dump root/object attributes
  [ 'root', 'object' ].each { |object_type| $evm.instantiate("/Common/Log/DumpAttrs?object_type=#{object_type}") if @debug == true }

  # ensure we are using this method in the proper context
  case $evm.root['vmdb_object_type']
    # provision/rollback
    when 'miq_provision'
      prov = $evm.root['miq_provision']
      vm   = prov.vm || prov.destination rescue nil
    # retire
    when 'vm'
      vm   = $evm.root['vm']
      prov = vm.miq_provision rescue nil
    else
      raise "Invalid $evm.root['vmdb_object_type']: #{$evm.root['vmdb_object_type']}"
  end

  # get relevant options from provisioning object and debug logging
  if prov
    log(:info, "Inspecting provisioning object: #{prov.inspect}") if @debug
    options_hash   = prov.get_option(:ws_values)
    options_hash ||= prov.get_tags
    
    if options_hash
      log(:info, "Inspecting options_hash: #{options_hash.inspect}")
      dialog_value = options_hash[DIALOG_KEY.to_sym] || options_hash[DIALOG_KEY]

        unless dialog_value.nil?
        log(:info, "Setting dialog_value: <#{dialog_value}> on $evm.root")
        $evm.root[DIALOG_KEY.to_s] = dialog_value.to_s
      else
        raise "Unable to determine dialog_value from dialog option: <#{DIALOG_KEY}> in options_hash: #{options_hash.inspect}"
      end
    else
      raise "Unable to find options_hash via ws_values or tags"
    end
  else
    raise "Could not find provisioning object"
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
    errors                    = prov.get_option(:errors)
    errors[:dialog_get_value] = message
    prov.set_option(:errors, errors)
  end

  # exit with something other than MIQ_OK status
  exit MIQ_ABORT
end
