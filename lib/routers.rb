# by yyynishi
require 'interfaces'

class Router

	attr_reader :dpid
	attr_reader :interfaces
	attr_reader :routing_table

	def initialize(options)
		@dpid = options.fetch(:dpid)
		@interfaces = options.fetch(:interfaces)
		@routing_table = options.fetch(:routes)
	end
end

class Routers
	def initialize()
	end
	def find_interfaces_by(dpid)
	end
	def find_interfaces_by(mac)
	end
	def find_routing_table_by(dpid)
	end
end	