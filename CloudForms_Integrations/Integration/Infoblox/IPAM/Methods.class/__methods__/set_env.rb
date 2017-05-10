#
# Description: Sets network environment to dynamically pull network/IPAM variables
# Author: Dustin Scott, Red Hat
#

begin
  # ====================================
  # define methods
  # ====================================

  # define log method
  def log(level, msg)
    $evm.log(level,"#{@org} Customization: #{msg}")
  end

  # ====================================
  # log beginning of method
  # ====================================

  # set method variables
  @method = $evm.current_method
  @org = $evm.root['tenant'].name rescue nil
  @debug = true

  # log entering method and dump root/object attributes
  $evm.instantiate('/System/CommonMethods/Log/LogBookend' + '?' + { :bookend_status => :enter, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  [ 'root', 'object' ].each { |object_type| $evm.instantiate("/System/CommonMethods/Log/DumpAttrs?object_type=#{object_type}") if @debug == true }

  # ====================================
  # set variables
  # ====================================

  # log setting variables
  log(:info, "Setting variables for method: #{@method}")

  # set provisioning object variables
  case $evm.root['vmdb_object_type']
  when 'vm'
    vm = $evm.root['vm'] rescue nil
    prov = vm.miq_provision rescue nil
    environment = vm.tags("cbp_environment").first rescue nil
  when 'miq_provision'
    prov = $evm.root['miq_provision'] rescue nil
    vm = prov.destination rescue nil
    ws_values = prov.get_option(:ws_values) rescue nil
    tags = prov.get_tags rescue nil
    environment = tags[:cbp_environment] || ws_values[:cbp_environment] || ws_values[:dialog_tag_0_cbp_environment] rescue nil
  else
    raise "Invalid $evm.root['vmdb_object_type']: #{$evm.root['vmdb_object_type']}"
  end
  environment ||= "default"

  # set vm variables
  vm_name = prov.get_option(:vm_target_hostname) || vm.name rescue nil

  # debug logging
  if @debug == true
    log(:info, "Inspecting VM: #{vm.inspect}") unless vm.nil?
    log(:info, "Inspecting Provisioning Object: #{prov.inspect}") unless prov.nil?
  end

  # ====================================
  # begin main method
  # ====================================

  # log entering main method
  log(:info, "Running main portion of ruby code on method: #{@method}")

  # set environment on object and log it
  log(:info, "Setting environment <#{environment}> on object")
  $evm.object['environment'] = environment

  # ====================================
  # log end of method
  # ====================================

  # log exiting method and exit with MIQ_OK status
  $evm.instantiate('/System/CommonMethods/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_OK

# set ruby rescue behavior
rescue => err
  # set error message
  message = "Unable to successfully complete method: <b>#{@method}</b>.  Could not set network environment for VM #{vm_name}."

  # log what we failed
  log(:error, message)
  log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")

  # get errors variables (or create new hash) and set message
  errors = prov.get_option(:errors) rescue nil
  errors ||= {}

  # set hash with this method error
  errors[:set_env_error] = message

  # set errors option
  prov.set_option(:errors, errors) if prov

  # log exiting method and exit with MIQ_ABORT status
  $evm.instantiate('/System/CommonMethods/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_ABORT
end
