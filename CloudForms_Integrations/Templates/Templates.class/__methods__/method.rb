#
# Description: <METHOD DESCRIPTION HERE>
# Author: <YOUR NAME HERE>
# Created On: <DATE>
# Requirements: <REQUIREMENTS GO HERE>
#

# ====================================
# set gem requirements
# ====================================

require 'rubygems'

# ====================================
# set global method variables
# ====================================

# set method variables
@method = $evm.current_method
@org    = $evm.root['tenant'].name
@debug  = $evm.root['debug'] || false

# set method constants
MY_CONSTANT = 2

# ====================================
# define methods
# ====================================

# define log method
def log(level, msg)
  $evm.log(level,"#{@org} Customization: #{msg}")
end

# ====================================
# begin main method
# ====================================

begin
  # dump root/object attributes
  [ 'root', 'object' ].each { |object_type| $evm.instantiate("/Common/Log/DumpAttrs?object_type=#{object_type}") if @debug == true }

  # ensure we are using this method in the proper context
  case $evm.root['vmdb_object_type']
  when 'vm'
    vm   = $evm.root['vm'] rescue nil
    prov = vm.miq_provision rescue nil
  when 'miq_provision'
    prov = $evm.root['miq_provision'] rescue nil
    vm   = prov.destination rescue nil
  else
    raise "Invalid $evm.root['vmdb_object_type']: #{$evm.root['vmdb_object_type']}"
  end

  #
  # YOUR CODE HERE
  #

  # ====================================
  # exit method
  # ====================================

  exit MIQ_OK

# set ruby rescue behavior
rescue => err
  # set error message
  message = "Error in method: <b>#{@method}</b>:  #{err}"
  
  # log what we failed
  log(:warn, message)
  log(:warn, "[#{err}]\n#{err.backtrace.join("\n")}")

  # get errors variables (or create new hash)
  errors = prov.get_option(:errors) rescue nil
  error ||= {}
  
  # set hash with this method error
  errors[:my_error] = message
  
  # set errors option
  prov.set_option(:errors, errors) if prov
        
  # log exiting method and exit with something besides MIQ_OK
  $evm.instantiate('/Common/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_WARN
end
