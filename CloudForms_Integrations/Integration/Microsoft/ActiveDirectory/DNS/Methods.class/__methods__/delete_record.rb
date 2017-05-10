#
# Description: Deletes a DNS record for a VM
# Requirements: 
#   -a DNS server like bind set up for dynamic DNS updates. For more
# information, see "man nsupdate".
#   -we are trying to pull the values 
# Author: Dustin Scott, Red Hat
#

begin
  # ====================================
  # set gem requirements
  # ====================================

  require 'ipaddr'
  
  # ====================================
  # define methods
  # ====================================

  # define log method
  def log(level, msg)
    $evm.log(level,"#{@org} Customization: #{msg}")
  end
  
  # method for performing the dynamic dns update
  def update_dns(ad_dns_server, zone, record_type, value1, value2)
    begin
      # log what we are doing
      log(:info, "Removing DNS entry on server: <#{ad_dns_server}>")
      log(:info, "DNS Remove Values: Zone <#{zone}>, Record Type <#{record_type}>, Value1 <#{value1}> Value2 <#{value2}>")
    
      # NOTE: this is generic for both forward and reverse record updates
      # A record: value1 = fqdn, value2 = ipaddress
      # PTR record: value1 = reverse ip, value2 = fqdn
      IO.popen("nsupdate", 'r+') do |f|
        f << <<-EOF
        server #{ad_dns_server}
          zone #{zone}
          update delete #{value1} #{record_type} #{value2}
          send
EOF
        f.close_write
      end
      
      # log a successful completion message
      log(:info, "Successfully removed #{record_type} record for #{value1}")
      return true
    rescue => err
      # log a failure message
      log(:error, "#{err.inspect}")
      log(:error, "Unable to successfully remove #{record_type} record for #{value1}")
      return false
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
      vm = prov.destination rescue nil
      ws_values = prov.get_option(:ws_values) rescue nil
      tags = prov.get_tags rescue nil
  else
    raise "Invalid $evm.root['vmdb_object_type']: #{$evm.root['vmdb_object_type']}"
  end
  raise 'Unable to find vm' if vm.nil?

  # set active directory dns variables
  ad_dns_domain = $evm.object['ad_dns_domain']
  ad_dns_server = $evm.object['ad_dns_server']
  raise 'Unable to determine ad_dns_domain to dynamically update' if ad_dns_domain.nil?
  raise 'Unable to determine ad_dns_server to dynamically update' if ad_dns_server.nil?

  # set vm variables
  # NOTE: try the vm first, the provision object second, and the custom attribute last
  ipaddress = vm.ipaddresses.first rescue nil
  ipaddress ||= prov.get_option(:ipaddr) if prov
  ipaddress ||= prov.get_option(:prov_ip_addr) if prov
  fqdn = "#{vm.name}.#{ad_dns_domain}"
  raise "Unable to find ipaddress for VM <#{vm.name}>" if ipaddress.nil?

  # ====================================
  # begin main method
  # ====================================

  # log entering main method
  log(:info, "Running main portion of ruby code on method: #{@method}")

  # remove the forward (a) record
  fwd_result = update_dns(ad_dns_server, ad_dns_domain, 'A', fqdn, ipaddress)
  raise "Unable to update A record for VM <#{vm.name}> and IP <#{ipaddress}>" if fwd_result == false

  # create the reverse ip record and zone name for the reverse record
  reverse_ip = IPAddr.new(ipaddress).reverse
  log(:info, "Reverse IP for VM <#{vm.name}>: #{reverse_ip}") if @debug == true
  ip_split = reverse_ip.split('.')
  1.times { ip_split.shift } # we have a class C, so we need the format X.X.X.in-addr.arpa
  reverse_zone = ip_split.join('.')
  log(:info, "Reverse Zone to update for VM <#{vm.name}>: #{reverse_zone}") if @debug == true

  # remove the reverse (ptr) record
  rev_result = update_dns(ad_dns_server, reverse_zone, 'PTR', reverse_ip, fqdn)
  raise "Unable to update PTR record for VM <#{vm.name}> and IP <#{ipaddress}>" if rev_result == false
  
  # ====================================
  # log end of method
  # ====================================
  
  # log exiting method and exit with MIQ_OK status
  $evm.instantiate('/System/CommonMethods/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_OK

# set ruby rescue behavior
rescue => err
  # set error message
  message = "Unable to successfully complete method: #{@method}. Error: #{err}"

  # log what we failed
  log(:warn, message)
  log(:warn, "#{err.backtrace.join("\n")}")

  # get errors variables (or create new hash) and set message
  retire_errors = prov.get_option(:retire_errors) rescue nil
  retire_errors ||= {}
  
  # set hash with this method error
  retire_errors[:ad_dns_error] = message
  
  # set errors option
  prov.set_option(:retire_errors, retire_errors) if prov

  # log exiting method and exit with something besides MIQ_OK
  $evm.instantiate('/System/CommonMethods/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_WARN
end
