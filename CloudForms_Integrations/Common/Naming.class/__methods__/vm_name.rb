#
# Description: Creates System Name based on dialog user inputs.
#
# Author:      : Dustin Scott, Red Hat
# Creation Date: 9-June-2017
#
# NOTES:
#   - Number of integers to use for Series is set via the NAMING_DIGITS constant
#

# ====================================
# set global method variables
# ====================================

# set method variables
@method = $evm.current_method
@org    = $evm.root['tenant'].name
@debug  = $evm.root['debug'] || false

#
# potential dialog prefix (e.g. PREFIX_my_option)
# potential prefixes dialog items (e.g. PREFIX_SUBPREFIX_my_option)
#
DIALOG_PREFIX    = 'dialog'
TAG_SUBPREFIX    = 'tag'
OPTION_SUBPREFIX = 'option'

#
# potential value prefixes
#
ARRAY_VALUE_PREFIX       = 'Array::'
PASS_VALUE_PREFIX        = 'Password::'
TAG_CONTROL_VALUE_PREFIX = 'Classification::'

#
# ORDERED_NAMING_VALUES:
#   The values, in order, to be placed in the naming sequence.
#
# Hash Keys: Logging purposes. Names to denote in logs which values are associated.
#
# Hash Values:
#   Symbols: pulled via options or tags
#   Strings: literal
#
# NAMING_DIGITS:
#   The number of digits (e.g. 01, 02, 03 = 2 AND 001, 002, 003 = 3) to be placed at the end of ORDERED_NAMING_VALUES
#
ORDERED_NAMING_VALUES = {
  :application => :sn_application,                                                        # 1 - application being provisioned
  :environment => :sn_environment,                                                        # 2 - environment provisioning to
  :platform    => ($evm.root['miq_provision'].source.platform.first.downcase rescue nil), # 3 - first character from template platform
  :location    => :sn_location,                                                           # 4 - the form factor of the system
  :form_factor => :sn_form_factor                                                         # 5 - form factor
}.freeze
NAMING_DIGITS         = 3

#
# Optional, set non critical values and their defaults if missing
#
NON_CRITICAL_VALUES   = {
  :environment => 'n'
}

#
# caps lock
#   DOWNCASE:
#     true:  forces downcase of the VM name
#     false: raw VM names from derived values
#
#   UPCASE_WINDOWS:
#     true:  forces windows to all upper case
#     false: does not modify windows system names
#
#   NOTE:
#     UPCASE_WINDOWS will override the DOWNCASE option in the case that the system provisioned is windows
#     as determined from the provisioning object.
#
DOWNCASE       = true
UPCASE_WINDOWS = false

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
  full_prefix = DIALOG_PREFIX + '_' + option_prefix
  0.upto(9) do |build_num|
    @value   = get_symbol_or_string_value((full_prefix + '_' + build_num.to_s + '_' + option.to_s))                      # least intrusive
    @value ||= get_symbol_or_string_value((DIALOG_PREFIX + '_' + option.to_s))                                           # slightly more intrusive
    @value ||= get_symbol_or_string_value((ARRAY_VALUE_PREFIX + full_prefix + '_' + build_num.to_s + '_' + option.to_s)) # most intrusive (tag control array)
    @value ||= get_symbol_or_string_value((PASS_VALUE_PREFIX + full_prefix + '_' + build_num.to_s + '_' + option.to_s))  # most intrusive (password)

    break if @value # break the loop if you have a value
  end
  return @value
end

# get tag value
def get_tag_value(prov, tag)
  log(:info, "get_tag_value: Parsing dialog options to attempt to get tag value for option: <#{tag}>")
  value   = prov.get_tags[tag.to_sym]               # try standard methods
  value ||= get_value_intrusive(TAG_SUBPREFIX, tag) # try intrusive methods

  log(:info, "get_tag_value: Returning value: <#{value}> for tag: <#{tag}>")
  return value
end

# get option value
def get_option_value(prov, option)
  log(:info, "get_option_value: Parsing dialog options to attempt to get value for option: <#{option}>")
  value   = prov.get_option(option.to_sym) || prov.get_option(option.to_s)                             # try standard methods
  value ||= @dialog_options[option.to_sym] || @dialog_options[option.to_s] unless @dialog_options.nil? # try standard methods if we have @dialog_options
  value ||= @ws_values[option.to_sym]      || @ws_values[option.to_s]      unless @ws_values.nil?      # try standard methods if we have @ws_values
  value ||= get_value_intrusive(OPTION_SUBPREFIX, option)                                              # try intrusive methods

  log(:info, "get_option_value: Returning value: <#{value}> for option: <#{option}>")
  return value
end

# get value from provisioning object
def get_prov_value(prov, option_or_tag)
  log(:info, "get_prov_value: Getting value for option_or_tag: <#{option_or_tag}>")

  # attempt to return a valid value
  value = get_tag_value(prov, option_or_tag) || get_option_value(prov, option_or_tag)

  # find the classification name if we used a tag control
  if value.to_s.include?(TAG_CONTROL_VALUE_PREFIX)
    tag_object = $evm.vmdb(:classification).find_by_id(value.split('::').last)

    if tag_object.nil?
      sanitized_value = nil
    else
      sanitized_value = tag_object.name
    end
  else
    sanitized_value = value
  end

  # log and return the proper value
  log(:info, "get_prov_value: Returning prov value: <#{sanitized_value}> for option_or_tag: <#{option_or_tag}>")
  return sanitized_value
end

# updates the naming_values array
def update_naming_values(name, value)
  log(:info, "update_naming_values: Adding to naming_values Array: #{@naming_values.inspect}")
  log(:info, "Name: <#{name}>, Value: <#{value}>")
  @naming_values.push(value)
end

# sets the name based on our case selections
def get_name_with_case(vm_name, prov)
  log(:info, "get_name_with_case: Getting proper character capitalization for vm_name: <#{vm_name}>")

  # adjust the vm name appropriately
  adjusted_vm_name = vm_name
  adjusted_vm_name = vm_name.downcase if DOWNCASE
  adjusted_vm_name = vm_name.upcase   if UPCASE_WINDOWS && prov.try(:source).try(:platform).try(:first).try(:downcase) == 'windows'

  log(:info, "get_name_with_case: Returning adjusted_vm_name: <#{adjusted_vm_name}>")
  return adjusted_vm_name
end

# get the derived name
def get_derived_name(prov)
  begin
    log(:info, "get_derived_name: Inspecting ORDERED_NAMING_VALUES: #{ORDERED_NAMING_VALUES.inspect}")

    # get dialog options and ws_values
    @dialog_options = get_dialog_options(prov)
    @ws_values      = prov.get_option(:ws_values)

    # log and check each value and push to naming values array
    @naming_values = []
    ORDERED_NAMING_VALUES.each do |name, value|
      if value.nil?
        if NON_CRITICAL_VALUES[name].nil?
          raise "Unable to find critical element <#{name}> in naming VM"
        else
          update_naming_values(name, NON_CRITICAL_VALUES[name])
        end
      elsif value.is_a?(String)
        update_naming_values(name, value)
      elsif value.is_a?(Symbol)
        log(:info, "get_derived_name: Value <#{value}> for <#{name}> is a Symbol.  Attempting to pull via options and tags.")
        dialog_value = get_prov_value(prov, value)

        if dialog_value.nil?
          if NON_CRITICAL_VALUES[name].nil?
            raise "Unable to find dialog_value for <#{value}>"
          else
            update_naming_values(name, NON_CRITICAL_VALUES[name])
          end
        else
          update_naming_values(name, dialog_value)
        end
      else
        raise "Value <#{value}> is not a Symbol or String."
      end
    end

    # set the derived name
    if $evm.object['vm_prefix']
      derived_name = get_name_with_case("#{$evm.object['vm_prefix']}#{@naming_values.join}", prov)
    else
      derived_name = get_name_with_case(@naming_values.join, prov)
    end

    # log and return the derived vm name
    log(:info, "get_derived_name: Derived a VM Name: <#{derived_name}> + NAMING_DIGITS <#{NAMING_DIGITS}>")
    return derived_name + "$n{#{NAMING_DIGITS}}"
  rescue => err
    log(:error, "get_derived_name: #{err}")
    return nil
  end
end

# log final name and update it on the object
def update_vm_name(name, prov)
  log(:info, "update_vm_name: VM Name: <#{name}>")
  $evm.object['vmname'] = name
end

# ====================================
# begin main method
# ====================================

begin
  # ensure we are using this method in the proper context
  case $evm.root['vmdb_object_type']
    when 'miq_provision', 'miq_provision_request'
      prov = $evm.root['miq_provision_request'] || $evm.root['miq_provision'] || $evm.root['miq_provision_request_template']
    when 'miq_provision_request_template'
      exit MIQ_OK
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
    if current_vm_name.blank? || current_vm_name.nil? || current_vm_name == 'changeme'
      derived_name = get_derived_name(prov)
    else
      if vms_requested == 1
        derived_name = current_vm_name
      else
        derived_name = "#{current_vm_name}$n{#{NAMING_DIGITS}}"
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
  exit MIQ_ABORT
end
