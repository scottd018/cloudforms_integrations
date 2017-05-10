#
# Description: Create a DNS A record for a VM name and an IP address that Infoblox is setting
# Requirements: a DNS server like bind set up for dynamic DNS updates. For more
# information, see "man nsupdate".
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
  def update_dns(ad_dns_server, zone, ad_dns_ttl, record_type, value1, value2)
    begin
      # log what we are doing
      log(:info, "Creating dynamic DNS entry to server: <#{ad_dns_server}>")
      log(:info, "DNS Update Values: Zone <#{zone}>, TTL <#{ad_dns_ttl}>, Record Type <#{record_type}>, Value1 <#{value1}> Value2 <#{value2}>")
    
      # NOTE: this is generic for both forward and reverse record updates
      # A record: value1 = fqdn, value2 = ipaddress
      # PTR record: value1 = reverse ip, value2 = fqdn
      IO.popen("nsupdate", 'r+') do |f|
        f << <<-EOF
        server #{ad_dns_server}
          zone #{zone}
          update add #{value1} #{ad_dns_ttl} #{record_type} #{value2}
          send
EOF

        f.close_write
      end
    
      # log a successful completion message
      log(:info, "Successfully added #{record_type} record for #{value1}")
      return true
    rescue => err
      # log failure message
      log(:error, "#{err.inspect}")
      log(:error, "Unable to successfully add #{record_type} record for #{value1}")
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
  raise 'Unable to find provisioning object' if prov.nil?

  # set active directory dns variables
  ad_dns_domain = $evm.object['ad_dns_domain']
  ad_dns_server = $evm.object['ad_dns_server']
  ad_dns_ttl = $evm.object['ad_dns_ttl']
  raise 'Unable to determine ad_dns_domain to dynamically update' if ad_dns_domain.nil?
  raise 'Unable to determine ad_dns_server to dynamically update' if ad_dns_server.nil?
  raise 'Unable to determine ad_dns_ttl for dynamic update' if ad_dns_ttl.nil?

  # set vm variables
  vm_name = prov.get_option(:vm_target_name) rescue nil
  ipaddress = prov.get_option(:ip_addr) rescue nil
  fqdn = "#{vm_name}.#{ad_dns_domain}" rescue nil
  raise "Unable to find ipaddress for VM <#{vm_name}>" if ipaddress.nil?
  raise "Unable to determine fqdn" if fqdn.nil?

  # ====================================
  # begin main method
  # ====================================

  # log entering main method
  log(:info, "Running main portion of ruby code on method: #{@method}")

  # update the forward (a) record
  fwd_result = update_dns(ad_dns_server, ad_dns_domain, ad_dns_ttl, 'A', fqdn, ipaddress)
  raise "Unable to update A record for VM <#{vm_name}> and IP <#{ipaddress}>" if fwd_result == false

  # create the reverse ip record and zone name for the reverse record
  reverse_ip = IPAddr.new(ipaddress).reverse
  log(:info, "Reverse IP for VM <#{vm_name}>: #{reverse_ip}") if @debug == true
  ip_split = reverse_ip.split('.')
  1.times { ip_split.shift } # we have a class C, so we need the format X.X.X.in-addr.arpa
  reverse_zone = ip_split.join('.')
  log(:info, "Reverse Zone to update for VM <#{vm_name}>: #{reverse_zone}") if @debug == true

  # update the reverse (ptr) record
  rev_result = update_dns(ad_dns_server, reverse_zone, ad_dns_ttl, 'PTR', reverse_ip, fqdn)
  raise "Unable to update PTR record for VM <#{vm_name}> and IP <#{ipaddress}>" if rev_result == false

  # create custom values on the vm object and provision object for retirement
  # NOTE: this is because the retirement process shuts down the vm at the beginning of retirement and removes
  # the ability to pull things like the ip address before the shutdown occurs.  we could move the dns removal before
  # this happens, but we may want dns for things later in the retirement process, so we won't do that
  prov.set_option(:prov_ip_addr, ipaddress)
  prov.set_option(:prov_dns_domain, ad_dns_domain)

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
  log(:error, message)
  log(:error, "#{err.backtrace.join("\n")}")

  # get errors variables (or create new hash) and set message
  errors = prov.get_option(:errors) rescue nil
  errors ||= {}
  
  # set hash with this method error
  errors[:ad_dns_error] = message
  
  # set errors option
  prov.set_option(:errors, errors) if prov

  # log exiting method and exit with something besides MIQ_OK
  $evm.instantiate('/System/CommonMethods/Log/LogBookend' + '?' + { :bookend_status => :exit, :bookend_parent_method => @method, :bookend_org => @org }.to_query)
  exit MIQ_ABORT
end
