module Moped
  class Socket

    # Thread-safe atomic integer.
    class RequestId
      def initialize
        @mutex = Mutex.new
        @id = 0
      end

      def next
        @mutex.synchronize { @id += 1 }
      end
    end

    attr_reader :connection

    attr_reader :host
    attr_reader :port

    def initialize(host, port)
      @host = host
      @port = port

      @mutex = Mutex.new
      @request_id = RequestId.new
    end

    def connect
      return true if connection

      @connection = TCPSocket.open host, port
    rescue Errno::ECONNREFUSED
      false
    end

    # @return [true, false] whether this socket connection is alive
    def alive?
      if connection
        return false if connection.closed?

        readable, = IO.select([connection], [connection], [])

        if readable[0]
          begin
            !connection.eof?
          rescue Errno::ECONNRESET
            false
          end
        else
          true
        end
      else
        false
      end
    end

    # Execute the operation on the connection.
    def execute(*ops)
      buf = ""

      last = ops.each do |op|
        op.request_id = @request_id.next
        op.serialize buf
      end.last

      @mutex.lock
      connection.write buf

      if Protocol::Query === last || Protocol::GetMore === last
        length, = connection.read(4).unpack('l<')
        data = connection.read(length - 4)
        @mutex.unlock

        parse_reply length, data
      else
        @mutex.unlock

        nil
      end
    end

    def parse_reply(length, data)
      buffer = StringIO.new data

      reply = Protocol::Reply.allocate

      reply.length = length

      reply.request_id,
        reply.response_to,
        reply.op_code,
        reply.flags,
        reply.cursor_id,
        reply.offset,
        reply.count = buffer.read(32).unpack('l4<q<l2<')

      reply.documents = reply.count.times.map do
        BSON::Document.deserialize(buffer)
      end

      reply
    end

    # Executes a simple (one result) query and returns the first document.
    #
    # @return [Hash] the first document in a result set.
    def simple_query(query)
      query = query.dup
      query.limit = -1

      execute(query).documents.first
    end

    # Manually closes the connection
    def close
      @mutex.synchronize do
        connection.close if connection && !connection.closed?
        @connection = nil
      end
    end

  end
end
