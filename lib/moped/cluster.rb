module Moped

  class Cluster

    # @return [Array] the user supplied seeds
    attr_reader :seeds

    # @return [Boolean] whether this is a direct connection
    attr_reader :direct

    # @return [Array] available master connections
    attr_reader :masters

    # @return [Array] available slave connections
    attr_reader :slaves

    # @return [Array] all available connections
    attr_reader :servers

    # @return [Array] seeds gathered from cluster discovery
    attr_reader :dynamic_seeds

    # @param [String] seeds a comma separated list of host:port pairs
    # @param [Boolean] direct (false) whether to connect directly to the hosts
    # provided or to find additional available nodes.
    def initialize(seeds, direct = false)
      @seeds  = parse_hosts seeds
      @direct = direct

      @servers = []
      @masters = []
      @slaves  = []
      @dynamic_seeds = []
    end

    def remove(socket)
      masters.delete socket
      slaves.delete socket
      servers.delete socket
    end

    def sync
      seeds.each do |host, port|
        sync_socket Socket.new(host, port)
      end
    end

    def sync_socket(socket)
      unless socket.connect
        raise Errors::ConnectionFailure.new("Failed to connect to node #{socket.host}:#{socket.port}")
      end

      is_master = socket.simple_query Protocol::Command.new(:$admin, ismaster: 1)

      if is_master["info"]
        raise Errors::ConnectionFailure.new("Failed to connect to node #{socket.host}:#{socket.port}: #{is_master["info"]}")
      end

      if is_master["ismaster"]
        servers << socket
        masters << socket
      elsif is_master["secondary"]
        servers << socket
        slaves  << socket
      else
        socket.close
      end
    end

    # @param [:read, :write] mode the type of socket to return
    # @return [Socket] a socket valid for +mode+ operations
    def socket_for(mode)
      socket = nil

      until socket
        sync unless masters.any? || (slaves.any? && mode == :read)

        if mode == :write || slaves.empty?
          socket = masters.sample
        else
          socket = slaves.sample
        end

        unless socket.alive?
          remove socket
          socket = nil
        end
      end

      socket
    end

    private

    def parse_hosts(hosts)
      hosts.split(",").map do |host|
        host, port = host.split(":")
        [host, port.to_i]
      end
    end
  end

end
