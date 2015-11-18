require 'arp_table'
require 'interfaces'
require 'routing_table'

# Simple implementation of L3 switch in OpenFlow1.0
# rubocop:disable ClassLength

class SimpleRouter < Trema::Controller
#数字の大きい方から小さい方へのテーブル移動は
#bad_instructionsとかなってバグるので注意
  CLASSIFIER_TABLE_ID    = 0
#  ARP_RESPONDER_TABLE_ID = 2#だからこれも105じゃなくて小さい数字にしてる
#  L3_REWRITE_TABLE_ID    = 5
#  L3_ROUTING_TABLE_ID    = 10
#  L3_FORWARDING_TABLE_ID = 15
#  L2_REWRITE_TABLE_ID    = 20
#  L2_FORWARDING_TABLE_ID = 25
  ARP_RESPONDER_TABLE_ID = 2
  ROUTING_TABLE_ID  = 3
  INTERFACE_LOOKUP_TABLE_ID = 4
  ARP_LOOKUP_TABLE_ID = 5
  ETHER_TYPE_ARP = 0x0806
  ETHER_TYPE_IPv4 = 0x0800

  def start(_args)
    load File.join(__dir__, '..', 'simple_router.conf')
    @interfaces = Interfaces.new(Configuration::INTERFACES)
    @arp_table = ArpTable.new
    @routing_table = RoutingTable.new(Configuration::ROUTES)
    @unresolved_packet_queue = Hash.new { [] }
    logger.info "#{name} started."
  end

  def switch_ready(dpid)
    add_arp_flow_entry(dpid)
    add_ipv4_flow_entry(dpid)
    interface_hash = Configuration::INTERFACES
    logger.info"#{interface_hash}"
#    add_other_packets_flow_entry(dpid)
#    add_default_arp_entry(dpid)
#    add_default_l3_rewrite_entry(dpid)
#    add_default_l3_routing_entry(dpid)
#    add_default_l3_forwarding_entry(dpid)
#    add_default_l2_rewrite_entry(dpid)
#    add_default_l2_forwarding_entry(dpid)
#    send_flow_mod_delete(dpid, match: Match.new)
#    logger.info "finished switch ready"
  end

  # rubocop:disable MethodLength
  def packet_in(dpid, message)
    return unless sent_to_router?(message)

    case message.data
    when Arp::Request
      logger.info"Arp request from #{message.data.sender_protocol_address}"
      packet_in_arp_request dpid, message.in_port, message.data
      add_arp_request_flow_entry(dpid,message)
#    add_l2_forwarding_flow_entry(dpid, message)
    when Arp::Reply
      logger.info"Arp reply"
      packet_in_arp_reply dpid, message
#      add_l2_forwarding_flow_entry(dpid, message)
    when Parser::IPv4Packet
      logger.info"packet in ipv4"
      packet_in_ipv4 dpid, message
    else
      logger.debug "Dropping unsupported packet type: #{message.data.inspect}"
    end
  end
  # rubocop:enable MethodLength

  # rubocop:disable MethodLength
  def packet_in_arp_request(dpid, in_port, arp_request)
    interface =
      @interfaces.find_by(port_number: in_port,
                          ip_address: arp_request.target_protocol_address)
    return unless interface
    send_packet_out(
      dpid,
      raw_data: Arp::Reply.new(
        destination_mac: arp_request.source_mac,
        source_mac: interface.mac_address,
        sender_protocol_address: arp_request.target_protocol_address,
        target_protocol_address: arp_request.sender_protocol_address
      ).to_binary,
      actions: SendOutPort.new(in_port))
  end
  # rubocop:enable MethodLength

  def packet_in_arp_reply(dpid, message)
    @arp_table.update(message.in_port,
                      message.sender_protocol_address,
                      message.source_mac)
    flush_unsent_packets(dpid,
                         message.data,
                         @interfaces.find_by(port_number: message.in_port))
  end

  def packet_in_ipv4(dpid, message)
    if forward?(message)
      forward(dpid, message)
    elsif message.ip_protocol == 1
      icmp = Icmp.read(message.raw_data)
      packet_in_icmpv4_echo_request(dpid, message) if icmp.icmp_type == 8
    else
      logger.debug "Dropping unsupported IPv4 packet: #{message.data}"
    end
  end

  # rubocop:disable MethodLength
  def packet_in_icmpv4_echo_request(dpid, message)
    icmp_request = Icmp.read(message.raw_data)
    if @arp_table.lookup(message.source_ip_address)
      send_packet_out(dpid,
                      raw_data: create_icmp_reply(icmp_request).to_binary,
                      actions: SendOutPort.new(message.in_port))
    else
      send_later(dpid,
                 interface: @interfaces.find_by(port_number: message.in_port),
                 destination_ip: message.source_ip_address,
                 data: create_icmp_reply(icmp_request))
    end
  end
  # rubocop:enable MethodLength

  private

  def sent_to_router?(message)
    return true if message.destination_mac.broadcast?
    interface = @interfaces.find_by(port_number: message.in_port)
    interface && interface.mac_address == message.destination_mac
  end

  def forward?(message)
    !@interfaces.find_by(ip_address: message.destination_ip_address)
  end

  # rubocop:disable MethodLength
  # rubocop:disable AbcSize
  def forward(dpid, message)
    next_hop = resolve_next_hop(message.destination_ip_address)

    interface = @interfaces.find_by_prefix(next_hop)
    return if !interface || (interface.port_number == message.in_port)

    arp_entry = @arp_table.lookup(next_hop)
    if arp_entry
      actions = [SetSourceMacAddress.new(interface.mac_address),
                 SetDestinationMacAddress.new(arp_entry.mac_address),
                 SendOutPort.new(interface.port_number)]
      #send_flow_mod_add(dpid, match: ExactMatch.new(message), actions: actions)
      send_flow_mod_add(dpid,match: ExactMatch.new(message),instructions: Apply.new(actions))
      send_packet_out(dpid, raw_data: message.raw_data, actions: actions)
    else
      send_later(dpid,
                 interface: interface,
                 destination_ip: next_hop,
                 data: message.data)
    end
  end
  # rubocop:enable AbcSize
  # rubocop:enable MethodLength

  def resolve_next_hop(destination_ip_address)
    interface = @interfaces.find_by_prefix(destination_ip_address)
    if interface
      destination_ip_address
    else
      @routing_table.lookup(destination_ip_address)
    end
  end

  def create_icmp_reply(icmp_request)
    Icmp::Reply.new(identifier: icmp_request.icmp_identifier,
                    source_mac: icmp_request.destination_mac,
                    destination_mac: icmp_request.source_mac,
                    destination_ip_address: icmp_request.source_ip_address,
                    source_ip_address: icmp_request.destination_ip_address,
                    sequence_number: icmp_request.icmp_sequence_number,
                    echo_data: icmp_request.echo_data)
  end

  def send_later(dpid, options)
    destination_ip = options.fetch(:destination_ip)
    @unresolved_packet_queue[destination_ip] += [options.fetch(:data)]
    send_arp_request(dpid, destination_ip, options.fetch(:interface))
  end

  def flush_unsent_packets(dpid, arp_reply, interface)
    destination_ip = arp_reply.sender_protocol_address
    @unresolved_packet_queue[destination_ip].each do |each|
      rewrite_mac =
        [SetDestinationMacAddress.new(arp_reply.sender_hardware_address),
         SetSourceMacAddress.new(interface.mac_address),
         SendOutPort.new(interface.port_number)]
      send_packet_out(dpid, raw_data: each.to_binary_s, actions: rewrite_mac)
    end
    @unresolved_packet_queue[destination_ip] = []
  end

  def send_arp_request(dpid, destination_ip, interface)
    arp_request =
      Arp::Request.new(source_mac: interface.mac_address,
                       sender_protocol_address: interface.ip_address,
                       target_protocol_address: destination_ip)
    send_packet_out(dpid,
                    raw_data: arp_request.to_binary,
                    actions: SendOutPort.new(interface.port_number))
  end

  #coded by s-kojima
  def add_arp_flow_entry(dpid)
    send_flow_mod_add(
      dpid,
      table_id: CLASSIFIER_TABLE_ID,
      idle_timeout: 0,
      priority: 0,
      match: Match.new(
	ether_type: ETHER_TYPE_ARP,
        arp_operation: Arp::Request::OPERATION,
      ),
      instructions: GotoTable.new(ARP_RESPONDER_TABLE_ID)
    )
  end

  #coded by s-kojima
  def add_ipv4_flow_entry(dpid)
    send_flow_mod_add(
      dpid,
      table_id: CLASSIFIER_TABLE_ID,
      idle_timeout: 0,
      priority: 0,
      match: Match.new(ether_type: ETHER_TYPE_IPv4),
      instructions: GotoTable.new(L3_REWRITE_TABLE_ID)
    )
  end

  #coded by s-kojima
  def add_default_arp_entry(dpid)
    send_flow_mod_add(
      dpid,
      table_id: ARP_RESPONDER_TABLE_ID,
      idle_timeout: 0,
      priority: 0,
      match: Match.new,
      instructions: GotoTable.new(L2_REWRITE_TABLE_ID)
    )
  end
=begin
  #coded by s-kojima
  def add_default_l3_rewrite_entry(dpid)
    send_flow_mod_add(
      dpid,
      table_id: L3_REWRITE_TABLE_ID,
      idle_timeout: 0,
      priority: 0,
      match: Match.new,
      instructions: GotoTable.new(L3_ROUTING_TABLE_ID)
    )
  end

  #coded by s-kojima
  def add_default_l3_routing_entry(dpid)
    send_flow_mod_add(
      dpid,
      table_id: L3_ROUTING_TABLE_ID,
      idle_timeout: 0,
      priority: 0,
      match: Match.new,
      instructions: GotoTable.new(L3_FORWARDING_TABLE_ID)
    )
  end

  #coded by s-kojima
  def add_default_l3_forwarding_entry(dpid)
    send_flow_mod_add(
      dpid,
      table_id: L3_FORWARDING_TABLE_ID,
      idle_timeout: 0,
      priority: 0,
      match: Match.new,
      instructions: GotoTable.new(L2_REWRITE_TABLE_ID)
    )
  end


  #coded by s-kojima
  def add_default_l2_rewrite_entry(dpid)
    send_flow_mod_add(
      dpid,
      table_id: L2_REWRITE_TABLE_ID,
      idle_timeout: 0,
      priority: 0,
      match: Match.new,
      instructions: GotoTable.new(L2_FORWARDING_TABLE_ID)
    )
  end

  #coded by s-kojima
  def add_default_l2_forwarding_entry(dpid)
    send_flow_mod_add(
      dpid,
      table_id: L2_FORWARDING_TABLE_ID,
      idle_timeout: 0,
      priority: 0,
      match: Match.new,
      instructions: Apply.new(SendOutPort.new(:controller)),
    )
  end


  #coded by s-kojima
  def add_arp_request_flow_entry(dpid,message)
    interface =
      @interfaces.find_by(port_number: message.in_port,
                          ip_address:    
      message.data.target_protocol_address)
    return unless interface

    actions = [
           NiciraRegMove.new(from: :source_mac_address,
                             to: :destination_mac_address),
	   SetArpOperation.new(Arp::Reply::OPERATION),
	   SetSourceMacAddress.new(interface.mac_address),
	   SetArpSenderProtocolAddress.new(message.data.target_protocol_address),
           SetArpSenderHardwareAddress.new(interface.mac_address),
#	   NiciraRegMove.new(from: :arp_sender_hardware_address,to: :arp_target_hardware_address),
#          NiciraRegMove.new(from: :arp_sender_protocol_address,to: :arp_target_protocol_address)
           SendOutPort.new(:in_port)
	]

    send_flow_mod_add(
       dpid,
       table_id: ARP_RESPONDER_TABLE_ID,
       idle_timeout: 0,
       priority: 1,
       match: Match.new(
              ether_type: ETHER_TYPE_ARP,
              arp_operation: Arp::Request::OPERATION,
              arp_target_protocol_address: interface.ip_address),
       instructions: [Apply.new(actions),GotoTable.new(L2_REWRITE_TABLE_ID)])
  end

  #coded by s-kojima
  def add_other_packets_flow_entry(dpid)
    send_flow_mod_add(
      dpid,
      table_id: CLASSIFIER_TABLE_ID,
      idle_timeout: 0,
      priority: 0,
      match: Match.new,
      instructions: GotoTable.new(L3_REWRITE_TABLE_ID)
    )
  end

  #coded by s-kojima
  def add_l2_forwarding_flow_entry(dpid, message)
    send_flow_mod_add(
      dpid,
      table_id: L2_FORWARDING_TABLE_ID,
      idle_timeout: 0,
      priority: 1,
      match: Match.new(
        destination_mac_address: message.source_mac,
      ),
      instructions: Apply.new(SendOutPort.new(message.in_port)),
    )
  end
=end
end
# rubocop:enable ClassLength
