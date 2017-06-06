#
# Description: Code for cleaning up if system fails provisioning
# Author: Dustin Scott, Red Hat
# Updated On: Mar-17-2016
# 
# Required inputs:
#   - status: tells the cleanup whether the provisioning State Machine is in either pre_provision, provision, or post_provision status
#     - pre_provision: CFME administrator should add $evm.instantiate on all items that need cleaned up before provisioning
#     - provision: dependent on pre_provision.  CFME checks to see if a VM exists and retires if it does, but follows pre_provision steps
#       if a VM cannot be found.
#     - post_provision: initiates the retirement State Machine
#
# Turning auto_cleanup off:
#   - auto_cleanup_on_failure: located in /CBP_Variables/Common/AutoCleanup
#     - true: clean up everything upon provisioning failure
#     - false: leave default behavior in place
#

begin
  # ====================================
  # define methods
  # ====================================

  # define log method
  def log(level, msg)
    $evm.log(level,"#{@org} Customization: #{msg}")
  end
  
  # define method for cleanup during pre_provision state
  def pre_provision_cleanup(state, step)
    # steps for cleaning up if provisioning fails during pre_provision state
    log(:info, "Calling ReclaimIp for cleanup: #{state} on step #{step}")
    $evm.instantiate("/Integration/Infoblox/IPAM/Methods/ReclaimIp")
  end
  
  # define method for cleanup during provsion state
  def provision_cleanup(prov, state, step)
    # attempt to find the vm we are cleaning up
    vm = prov.destination || vm = prov.vm rescue nil
    
    # retire the vm if we found it, otherwise we are simply going to run the pre_provision_cleanup
    if vm.nil?
      log(:info, "Unable to find VM, which means it hasn't finished provisioning.  Running pre_provision cleanup steps.")
      pre_provision_cleanup(state, step)
    else
      log(:info, "Found VM: <#{vm.name}>.  Running VM retirement process.")
      vm.retire_now
    end
  end
  
  # define method for cleanup during post_provision state
  def post_provision_cleanup(prov)
    # attempt to find the vm we are cleaning up
    vm = prov.destination || vm = prov.vm rescue nil
    
    # retire the vm if we found it, otherwise we are simply going to run the pre_provision_cleanup
    unless vm.nil?
      # retire the vm
      vm.retire_now
    else
      raise 'Unable to find VM for cleanup'
    end
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
  when 'miq_provision'
    prov = $evm.root['miq_provision'] rescue nil
  else
    raise "Invalid $evm.root['vmdb_object_type']: #{$evm.root['vmdb_object_type']}"
  end
  raise 'Unable to find provisioning object' if prov.nil?

  # get the auto_cleanup_on_failure boolean to see if we should run this or not
  # NOTE: the auto_cleanup_on_failure is a switch to turn this behavior off (fallback to false if we can't pull it correctly)
  cleanup = $evm.instance_get('/CBP_Variables/Common/AutoCleanup/Default')['auto_cleanup_on_failure'] rescue false

  # get variables from server object
  server = $evm.root['miq_server']

  # get state machine variables
  state = $evm.current_object.class_name rescue nil
  step = $evm.current_object.current_field_name rescue nil

  # get status from state machine input
  status = $evm.inputs['status']

  # ====================================
  # begin main method
  # ====================================

  # log entering main method
  log(:info, "Running main portion of ruby code on method: #{@method}")

  # log our current status
  log(:info, "Server:<#{server.name}> Ae_Result:<#{$evm.root['ae_result']}> State:<#{state}> Step:<#{step}> Status:<#{status}> Cleanup:<#{cleanup}>")

  # set the message on the provsioning object
  prov.message = "AUTO-CLEANUP: Status: #{status}, Step: #{step}"

  # only run cleanup steps if our cleanup switch is true
  if (cleanup == true || cleanup == 'true')
    
    # run specific method depending on which step we reached
    case status
    when 'pre_provision'
      # run pre_provision cleanup steps
      pre_provision_cleanup(state, step)
    when 'provision'
      # run provision cleanup steps
      provision_cleanup(prov, state, step)
    when 'post_provision'
      # run post_provision cleanup steps
      post_provision_cleanup(prov)
    when nil
      log(:error, "Could not find [status] value. Skipping auto-cleanup.")
    else
      log(:info, "No valid status found.  Please use: pre_provision, provision, post_provision. Skipping auto-cleanup.")
    end
  else
    log(:info, "Found cleanup value of <#{cleanup}>.  Skipping auto-cleanup.")
    log(:info, "Set the cleanup value to <true> in the future to initiate auto-cleanup upon provisioning failure")
  end

  # ====================================
  # log end of method
  # ====================================
  
  # log exiting method and exit with MIQ_OK status
  $evm.instantiate('/System/CommonMethods/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_OK

# set ruby rescue behavior
rescue => err
  # set error message
  message = "Error in method: <b>#{@method}</b>:  #{err}"
  
  # log what we failed
  log(:error, message)
  log(:error, "[#{err}]\n#{err.backtrace.join("\n")}")

  # get errors variables (or create new hash)
  errors = prov.get_option(:errors) rescue nil
  errors ||= {}
  
  # set hash with this method error (collect errors throughout provisioning
  errors[:auto_cleanup_error] = message
  
  # set errors option
  prov.set_option(:errors, errors) if prov
        
  # log exiting method and exit with something besides MIQ_OK
  $evm.instantiate('/System/CommonMethods/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_ABORT
end
