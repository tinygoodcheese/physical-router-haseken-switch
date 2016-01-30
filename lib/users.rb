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
		@dpid = options.fetch(:dpid)
		@port_number = options.fetch(:port_number)
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

	def find_by_user_id_and_ip(user_id, ip_address)
		step1 = 
		@list.find_all do |user|
			user.user_id == user_id
		end
		print "step1:",step1,"\n"
		step2 =
		step1.find do |user|
			user.ip_address == ip_address
		end
		print "step2:",step2,"\n"
	end

	def find_by_ip_and_port(ip_address, port_number)
		step1 = 
		@list.find_all do |user|
			user.ip_address == ip_address
		end
#		print "step1_portnumber:",step1[0].port_number,"\n"
#		print "arg_portnumber:",port_number,"\n"
		step2 =
		step1.find do |user|
			print "step1_portnumber:",user.port_number,"\n"
			print "arg_portnumber:",port_number,"\n"
			user.port_number.to_i == port_number.to_i
		end
		return step2
		print "step2:",step2,"\n"
	end
	# modified by yyynishi
	#def find_by_mac(mac_address)
	#	@list.find do |user|
	#		user.mac_address == mac_address
	#	end
	#end
end