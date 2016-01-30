# -*- coding: utf-8 -*-
require 'arp_table'
require 'interfaces'
require 'routing_table'
### modified by tinygoodcheese
require 'users'
###

# Simple implementation of L3 switch in OpenFlow1.0
# rubocop:disable ClassLength
class SimpleRouter < Trema::Controller
  def start(_args)
    load File.join(__dir__, '..', 'simple_router.conf')
    @interfaces = Interfaces.new(Configuration::INTERFACES)
    @arp_table = ArpTable.new
    @routing_table = RoutingTable.new(Configuration::ROUTES)
    @unresolved_packet_queue = Hash.new { [] }
    @unresolved_packet_port_queue = Hash.new { [] }
### modified by tinygoodcheese
    @users = Users.new('users.conf')
###
    logger.info "#{name} started."
  end

  def switch_ready(dpid)
    send_flow_mod_delete(dpid, match: Match.new)
  end

  # rubocop:disable MethodLength
  def packet_in(dpid, message)
    return unless sent_to_router?(dpid,message)

    case message.data
    when Arp::Request
      packet_in_arp_request dpid, message.in_port, message.data
    when Arp::Reply
      packet_in_arp_reply dpid, message
    when Parser::IPv4Packet
      packet_in_ipv4 dpid, message
    else
      logger.debug "Dropping unsupported packet type: #{message.data.inspect}"
    end
  end
  # rubocop:enable MethodLength

  # rubocop:disable MethodLength
  def packet_in_arp_request(dpid, in_port, arp_request)
###modified by tinygoodcheese
    interface = @interfaces.find_by(dpid: dpid,
                                    port_number: in_port,
                                    ip_address: arp_request.target_protocol_address)
##      @interfaces.find_by(port_number: in_port,
##                          ip_address: arp_request.target_protocol_address)
    return unless interface
    send_packet_out(
      dpid,
      raw_data: Arp::Reply.new(
        destination_mac: arp_request.source_mac,
        source_mac: interface.mac_address,
        sender_protocol_address: arp_request.target_protocol_address,
        target_protocol_address: arp_request.sender_protocol_address
      ).to_binary,
      actions:SendOutPort.new(in_port))
  end
  # rubocop:enable MethodLength

  def packet_in_arp_reply(dpid, message)
    @arp_table.update(message.in_port,
                      message.sender_protocol_address,
                      message.source_mac)
    flush_unsent_packets(dpid,
                         message.data,
                         ### modified by tinygoodcheese
                         @interfaces.find_by(dpid: dpid,
                                             port_number: message.in_port))
 ##                      @interfaces.find_by(port_number: message.in_port)  )
  end

  def packet_in_ipv4(dpid, message)
    ### modified by tgc
    if forward?(dpid,message)
    ##if forward?(message)
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
                 ### modified by tinygoodcheese
                 interface: @interfaces.find_by(dpid: dpid,
                                                port_number: message.in_port),
                 ## interface: @interfaces.find_by(port_number: message.in_port),
                 destination_ip: message.source_ip_address,
                 data: create_icmp_reply(icmp_request),
                 ### modified by tgc
                 port_number: message.in_port
                 )
    end
  end
  # rubocop:enable MethodLength

  private
### modified by tinygoodcheese
  def sent_to_router?(dpid, message)
##  def sent_to_router?(message)
    return true if message.destination_mac.broadcast?
### modified by tinygoodcheese
    interface = @interfaces.find_by(dpid: dpid,
                                    port_number: message.in_port)
##    interface = @interfaces.find_by(port_number: message.in_port)
    interface && interface.mac_address == message.destination_mac
  end

  def forward?(dpid, message)
### modified by tinygoodcheese
    !@interfaces.find_by(dpid: dpid,
                         ip_address: message.destination_ip_address)
##   !@interfaces.find_by(ip_address: message.destination_ip_address)
  end

  # rubocop:disable MethodLength
  # rubocop:disable AbcSize
  def forward(dpid, message)
    print "Source MAC: ", message.source_mac , "\n"
    print "Destination MAC: ", message.destination_mac , "\n"
    print "Source IP: ", message.source_ip_address , "\n"
    print "Destination IP: ", message.destination_ip_address , "\n"
    print "User id(ToS): ", message.ip_type_of_service , "\n" ,"\n","\n"
    ###modified by tinygoodcheese
    next_hop = resolve_next_hop(dpid,message.destination_ip_address)
##   next_hop = resolve_next_hop(message.destination_ip_address)
  ###

### modified by tinygoodcheese
    if message.ip_type_of_service == 0x00 then
      ### modified by yyynishi
      interfaces_subset = @interfaces.find_subset_by(dpid)
      interfaces = Interfaces.new()
      interfaces_subset.each do |interface|
        interfaces.add(dpid: interface.dpid,
                     port: interface.port_number,
                     mac_address: interface.mac_address,
                     ip_address: interface.ip_address,
                     netmask_length: interface.netmask_length)
      end
      interface = interfaces.find_by_prefix(next_hop)
      #interface = @interfaces.find_by(dpid).find_by_prefix(next_hop)
    ### modified by yyynishi
    elsif message.ip_type_of_service != 0x00 then
    #elsif message.ip_type_of_service != 0x01 then
      port = @users.find_by_user_id_and_ip(user_id: message.ip_type_of_service,
                                           ip_address: next_hop).port_number

      interface = @interfaces.find_by(dpid: dpid,
                                      port_number: port)
      ##interface = @interfaces.find_by(mac_address: dest_mac)
      ###
    end
##    interface = @interfaces.find_by_prefix(next_hop)
    return if !interface || (interface.port_number == message.in_port)

    arp_entry = @arp_table.lookup(next_hop)
    if arp_entry
      ### modified by tinygoodcheese
      user_id = @users.find_by_ip_and_port(ip_address: message.destination_ip_address,
                               port_number: interface.port_number).user_id
      actions = [Pio::OpenFlow10::SetTos.new(tos: user_id),
                 SetSourceMacAddress.new(interface.mac_address),
                 SetDestinationMacAddress.new(arp_entry.mac_address),
                 SendOutPort.new(interface.port_number)]
      send_flow_mod_add(dpid, match: ExactMatch.new(message), instructions: Apply.new(actions))
      send_packet_out(dpid, raw_data: message.raw_data, actions: actions)
    else
      send_later(dpid,
                 interface: interface,
                 destination_ip: next_hop,
                 data: message.data,
                 port_number: message.in_port)
    end
  end
  # rubocop:enable AbcSize
  # rubocop:enable MethodLength

### modified by tinygoodcheese
  def resolve_next_hop(dpid, destination_ip_address)
###  def resolve_next_hop(destination_ip_address)
###
### modified by tinygoodcheese

  interfaces_subset = @interfaces.find_subset_by(dpid)
  interfaces = Interfaces.new()
  interfaces_subset.each do |interface|
    interfaces.add(dpid: interface.dpid,
                   port: interface.port_number,
                   mac_address: interface.mac_address,
                   ip_address: interface.ip_address,
                   netmask_length: interface.netmask_length)
  end
    interface = interfaces.find_by_prefix(destination_ip_address)
   ## interface = @interfaces.find_by_prefix(destination_ip_address)
    if interface
      destination_ip_address
    else
### modified by tinygoodcheese
      @routing_table.lookup(dpid,
                            destination_ip_address)
##      @routing_table.lookup(destination_ip_address)
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
    ### modified by tgc
    @unresolved_packet_port_queue[destination_ip] += [options.fetch(:port_number)]
    send_arp_request(dpid, destination_ip, options.fetch(:interface))
  end

  def flush_unsent_packets(dpid, arp_reply, interface)
    destination_ip = arp_reply.sender_protocol_address
    unsent_packet_number = 0
    @unresolved_packet_queue[destination_ip].each do |each|
    in_port = @unresolved_packet_port_queue[destination_ip][unsent_packet_number]
      ### modified by yyynishi
      print "in_port:", in_port , "\n"
      print "data_source_ip_address:", each.source_ip_address,"\n" "\n"


      user_id = @users.find_by_ip_and_port(each.source_ip_address,
                               in_port).user_id.hex


      unsent_packet_number = unsent_packet_number + 1       
      
      print 'user_id:', user_id, "\n"
      @users.list.each do |user|
        print "user:" ,user,"\n"
        print "id:" ,user.user_id,"\n"
        print "ip_address", user.ip_address, "\n"
        print "port:" , user.port_number, "\n"
      end      
      ### modified by tinygoodcheese
      rewrite_mac =
         [Pio::OpenFlow10::SetTos.new(tos: user_id),
         SetDestinationMacAddress.new(arp_reply.sender_hardware_address),
         SetSourceMacAddress.new(interface.mac_address),
         SendOutPort.new(interface.port_number)]
      send_packet_out(dpid, raw_data: each.to_binary_s, actions: rewrite_mac)
    end
    @unresolved_packet_queue[destination_ip] = []
    @unresolved_packet_port_queue[destination_ip] = []

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
end
# rubocop:enable ClassLength
