#
# Description: Creates System Name with following format:
#
# Author:      : Dustin Scott, Red Hat
# Creation Date: 9-June-2017
#
# NOTES:
#   - Number of integers to use for Series is set via the SERIES_COUNT constant
#   - Assumes downcase of System Names
#

# ====================================
# set global method variables
# ====================================

# set method variables
@method = $evm.current_method
@org    = $evm.root['tenant'].name
@debug  = $evm.root['debug'] || false

# set method constants
SUPER_PREFIX       = 'dialog'
TAG_PREFIX         = 'tag'
OPTION_PREFIX      = 'option'
ARRAY_PREFIX       = 'Array::'
PASS_PREFIX        = 'Password::'
TAG_CONTROL_PREFIX = 'Classification::'

#
# ORDERED_NAMING_VALUES:
# The values, in order, to be placed in the naming sequence.
#
# Hash Keys: Logging purposes. Names to denote in logs which values are associated.
#
# Hash Values:
#   Symbols: pulled via options or tags
#   Strings: literal
#
# SERIES_COUNT:
# An instance number (e.g. 01, o2, 03) to be placed at the end of ORDERED_NAMING_VALUES
#
ORDERED_NAMING_VALUES = {
  :group_prefix => ($evm.root['user'].current_group.tags('group_prefix').first.downcase rescue nil), # 1 - group prefix tag on group
  :separator1   => '-',                                                                              # 2 - separator
  :system_type  => :sn_system_type,                                                                  # 3 - system type
  :separator2   => '-',                                                                              # 4 - separator
  :platform     => ($evm.root['miq_provision'].source.platform.first.downcase rescue nil),           # 5 - first character from template platform
  :form_factor  => :sn_form_factor,                                                                  # 6 - form factor
  :environment  => :sn_environment                                                                   # 7 - environment
}.freeze
SERIES_COUNT = 2

# ====================================
# define methods
# ====================================

# define log method
def log(level, msg)
  $evm.log(level,"#{@org} Automation: #{msg}")
end

# get all dialog options
def get_dialog_options(prov)
  log(:info, "get_dialog_options: Getting dialog options from prov")
  dialog_options = prov.miq_request.get_option(:dialog) || prov.get_option(:dialog)
  log(:info, "get_dialog_options: Returning dialog_options: #{dialog_options.inspect}")

  return dialog_options
end

# attempt to get the value as both a symbol and string
def get_symbol_or_string_value(option)
  log(:info, "get_symbol_or_string_value: Attempting to get option: <#{option}> as a symbol or string") if @debug
  value   = nil
  value ||= @dialog_options[option.to_s]   unless @dialog_options.nil?
  value ||= @dialog_options[option.to_sym] unless @dialog_options.nil?
  log(:info, "get_symbol_or_string_value: Returning value: <#{value}>") if @debug
  return value
end

# try intrusive methods to get a value
# TODO: untested past tag_0, option_0, etc.  Likely will need updated.
def get_value_intrusive(option_prefix, option)
  full_prefix = SUPER_PREFIX + '_' + option_prefix
  0.upto(9) do |build_num|
    @value   = get_symbol_or_string_value((full_prefix + '_' + build_num.to_s + '_' + option.to_s))                # least intrusive
    @value ||= get_symbol_or_string_value((SUPER_PREFIX + '_' + option.to_s))                                      # slightly more intrusive
    @value ||= get_symbol_or_string_value((ARRAY_PREFIX + full_prefix + '_' + build_num.to_s + '_' + option.to_s)) # most intrusive (tag control array)
    @value ||= get_symbol_or_string_value((PASS_PREFIX + full_prefix + '_' + build_num.to_s + '_' + option.to_s))  # most intrusive (password)

    break if @value # break the loop if you have a value
  end
  return @value
end

# get tag value
def get_tag_value(prov, tag)
  log(:info, "get_tag_value: Parsing dialog options to attempt to get tag value for option: <#{tag}>")
  value   = prov.get_tags[tag.to_sym]            # try standard methods
  value ||= get_value_intrusive(TAG_PREFIX, tag) # try intrusive methods

  log(:info, "get_tag_value: Returning value: <#{value}> for tag: <#{tag}>")
  return value
end

# get option value
def get_option_value(prov, option)
  log(:info, "get_option_value: Parsing dialog options to attempt to get value for option: <#{option}>")
  value   = prov.get_option(option.to_sym)                                                             # try standard methods
  value ||= @dialog_options[option.to_sym] || @dialog_options[option.to_s] unless @dialog_options.nil? # try standard methods if we have @dialog_options
  value ||= @ws_values[option.to_sym]      || @ws_values[option.to_s]      unless @ws_values.nil?      # try standard methods if we have @ws_values
  value ||= get_value_intrusive(OPTION_PREFIX, option)                                                 # try intrusive methods

  log(:info, "get_option_value: Returning value: <#{value}> for option: <#{option}>")
  return value
end

# get provisioning option
def get_prov_option(prov, option)
  log(:info, "get_prov_option: Getting prov option: <#{option}>")

  # get the dialog options and attempt to return a valid value
  @dialog_options = get_dialog_options(prov)    unless @dialog_options
  @ws_values      = prov.get_option(:ws_values) unless @ws_values
  value           = get_tag_value(prov, option) || get_option_value(prov, option)

  # find the classification name if we used a tag control
  if value.nil?
    return value
  else
    if value.include?(TAG_CONTROL_PREFIX)
      tag_object = $evm.vmdb(:classification).find_by_id(value.split('::').last)

      if tag_object.nil?
        sanitized_value = nil
      else
        sanitized_value = tag_object.name
      end

      log(:info, "get_prov_option: Returning prov value: <#{sanitized_value}> for option: <#{option}>")
      return sanitized_value
    else
      log(:info, "get_prov_option: Returning prov value: <#{value}> for option: <#{option}>")
      return value
    end
  end
end

# updates the naming_values array
def update_naming_values(name, value)
  log(:info, "update_naming_values: Adding to naming_values Array: #{@naming_values.inspect}")
  log(:info, "Name: <#{name}>, Value: <#{value}>")
  @naming_values.push(value)
end

# set derived_name
def set_derived_name(prov)
  begin
    log(:info, "set_derived_name: Inspecting ORDERED_NAMING_VALUES: #{ORDERED_NAMING_VALUES.inspect}") if @debug

    # log and check each value and push to naming values array
    @naming_values = []
    ORDERED_NAMING_VALUES.each do |name, value|
      if value.nil?
        raise "Unable to find critical element <#{name}> in naming VM"
      elsif value.is_a?(String)
        update_naming_values(name, value)
      elsif value.is_a?(Symbol)
        log(:info, "set_derived_name: Value <#{value}> for <#{name}> is a Symbol.  Attempting to pull via options and tags.")
        dialog_value = get_prov_option(prov, value)

        if dialog_value.nil?
          raise "Unable to find dialog value for <#{value}>"
        else
          update_naming_values(name, dialog_value)
        end
      else
        raise "Value <#{value}> is not a Symbol or String."
      end
    end

    # set the derived name
    derived_name = nil
    if $evm.object['vm_prefix']
      derived_name = "#{$evm.object['vm_prefix']}#{@naming_values.join}".downcase
    else
      derived_name = @naming_values.join.downcase
    end

    # log and return the derived vm name
    log(:info, "Derived VM Name: <#{derived_name}>")
    return derived_name + "$n{#{SERIES_COUNT}}"
  rescue => err
    log(:error, "set_derived_name: #{err}")
    return nil
  end
end

# log final name and update it on the object
def update_vm_name(name, prov)
  log(:info, "VM Name: <#{name}>")
  $evm.object['vmname'] = name
end

# ====================================
# begin main method
# ====================================

begin
  # log entering method and dump root/object attributes
  $evm.instantiate('/Common/Log/LogBookend' + '?' + { :bookend_status => :enter, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  [ 'root', 'object' ].each { |object_type| $evm.instantiate("/Common/Log/DumpAttrs?object_type=#{object_type}") } if @debug

  # ensure we are using this method in the proper context
  case $evm.root['vmdb_object_type']
    when 'miq_provision', 'miq_provision_request', 'miq_provision_request_template'
      prov = $evm.root['miq_provision_request'] || $evm.root['miq_provision'] || $evm.root['miq_provision_request_template']
    else
      raise "Invalid $evm.root['vmdb_object_type']: #{$evm.root['vmdb_object_type']}"
  end

  # get relevant options from provisioning object and debug logging
  if prov
    log(:info, "Inspecting provisioning object: #{prov.inspect}") if @debug
    current_vm_name = prov.get_option(:vm_name).to_s.strip
    vms_requested   = prov.get_option(:number_of_vms)

    # log current name and number of vms requested from dialog
    log(:info, "current_vm_name from dialog: <#{current_vm_name}>; vms_requested from dialog: <#{vms_requested}>")

    # no vm name chosen from dialog, or changeme requested
    if current_vm_name.blank? || current_vm_name == 'changeme'
      derived_name = set_derived_name(prov)
    else
      if vms_requested == 1
        derived_name = current_vm_name
      else
        derived_name = "#{current_vm_name}$n{#{SERIES_COUNT}}"
      end
    end

    # set the vm name if we derived one successfully
    if derived_name
      update_vm_name(derived_name, prov)
    else
      raise "Unable to determine derived_name"
    end
  else
    raise "Could not find provisioning object"
  end

  # ====================================
  # log end of method
  # ====================================

  # log exiting method and exit with MIQ_OK status
  $evm.instantiate('/Common/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_OK

# set ruby rescue behavior
rescue => err
  # go back to default naming if we have an error
  log(:warn, "Reverting to default vm_name")
  log(:warn, "[#{err}]\n#{err.backtrace.join("\n")}")

  # if we have prov, run through a routine
  if prov
    # inspect objects for debugging purposes
    log(:info, "Inspecting prov object: #{prov.inspect}")

    # log and update the vm name
    update_vm_name(current_vm_name, prov)

    # get errors variables (or create new hash) and set message
    message = "Unable to successfully complete method: <b>#{@method}</b>.  #{err}.  VM Naming may be incorrect."
    errors  = prov.get_option(:errors) || {}

    # set hash with this method error
    errors[:vm_name_error] = message
    prov.set_option(:errors, errors)
  end

  # log exiting method
  $evm.instantiate('/Common/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_WARN
end