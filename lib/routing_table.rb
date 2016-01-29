require 'pio'

# Routing table
class RoutingTable
  include Pio

  MAX_SWITCH = 8
  MAX_NETMASK_LENGTH = 32

  def initialize(route)
#    @db = Array.new(MAX_NETMASK_LENGTH + 1) { Hash.new }
    @db = Array.new(MAX_SWITCH+1) { Array.new(MAX_NETMASK_LENGTH+1, Hash.new)}
    route.each { |each| add(each) }
  end

  def add(options)
    # modified by yyynishi, dpip is added
    dpid = options.fetch(:dpid)
    netmask_length = options.fetch(:netmask_length)
    prefix = IPv4Address.new(options.fetch(:destination)).mask(netmask_length)
    @db[dpid][netmask_length][prefix.to_i] = IPv4Address.new(options.fetch(:next_hop))
  end

  # modified by uuunishi, dpid is added
  def lookup(dpid, destination_ip_address)
     MAX_NETMASK_LENGTH.downto(0).each do |each|
        prefix = destination_ip_address.mask(each)
        entry = @db[dpid][each][prefix.to_i]
        return entry if entry
      end
      nil 
  end
#  def lookup(destination_ip_address)
#    MAX_NETMASK_LENGTH.downto(0).each do |each|
#      prefix = destination_ip_address.mask(each)
#      entry = @db[each][prefix.to_i]
#      return entry if entry
#    end
#    nil
#  end
end