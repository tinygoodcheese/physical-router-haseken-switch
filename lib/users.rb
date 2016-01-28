# by yyynishi
require 'active_support/core_ext/class/attribute_accessors'
#require 'json'
#require 'path_manager'
#require 'port'
#require 'interfaces'

# IaaS VM
class User
	include Pio

  attr_reader :user_id
  attr_reader :ip_address
  attr_reader :mac_address

  def initialize(options)
    @dpid = options.fetch(:user_id)
    @ip_address = IPv4Address.new(options.fetch(:ip_address))
    @mac_address = Mac.new(options.fetch(:mac_address))
  end
end

class Users
	def initialize(filename)
		File.open(filename) do |file|
			file.each_line do |line| # user_id	ip_address	mac_address
				next if file.lineno == 1	# line 1 skip
				next if line =~ /^\s*$/	# blank line slip
				next if line =~ /^#/	# comment out skip
			
				words = line.split
				@list.push(User.new(user_id: words[0], ip_address: words[1], mac_address: words[2]))
			end
		end
	end

	def find_by(ip_address, mac_address)
	end

	def find_by(user_id, ip_address)
	end
end
