# by yyynishi
require 'pio'

# IaaS VM
class User
	include Pio

	attr_reader :user_id
	attr_reader :ip_address
	attr_reader :dpid
	attr_reader :port_number

	def initialize(options)
		@user_id = options.fetch(:user_id)
		@ip_address = IPv4Address.new(options.fetch(:ip_address))
		@dpid = Mac.new(options.fetch(:dpid))
		@port_number = Mac.new(options.fetch(:port_number))
	end
end

class Users

	attr_reader :list
	def initialize(filename)
		@list = Array.new()
		File.open(filename) do |file|
			file.each_line do |line| # user_id	ip_address	mac_address
				next if file.lineno == 1	# line 1 skip
				next if line =~ /^\s*$/	# blank line slip
				next if line =~ /^#/	# comment out skip
			
				words = line.split
				@list.push(User.new(user_id: words[0], ip_address: words[1], dpid: words[2], port_number: words[3]))
			end
		end
	end

	def find_by(queries)
		queries.inject(@list) do |memo, (attr, value)|
	    	memo.find_all do |user|
	        	user.__send__(attr) == value
	      	end
	    end.first
	end

	# modified by yyynishi
	#def find_by_mac(mac_address)
	#	@list.find do |user|
	#		user.mac_address == mac_address
	#	end
	#end
end