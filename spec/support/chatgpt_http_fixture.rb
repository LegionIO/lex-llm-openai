# frozen_string_literal: true

require 'socket'

# Replaces only the remote peer. Provider, shared Connection, HTTP adapter and
# Canonical boundaries remain real. All account/token values are synthetic.
class ChatgptHttpFixture
  attr_reader :requests

  def initialize
    @server = TCPServer.new('127.0.0.1', 0)
    @replies = Queue.new
    @requests = Queue.new
    @thread = Thread.new { serve }
    @thread.report_on_exception = false
  end

  def url
    "http://127.0.0.1:#{@server.addr[1]}/backend-api/"
  end

  def reply(body:, status: 200, content_type: 'text/event-stream', headers: {})
    @replies << { body: body, status: status, content_type: content_type, headers: headers }
  end

  def close
    @thread.kill
    @thread.join
    @server.close
  end

  private

  def serve
    loop do
      socket = @server.accept
      begin
        request = read_request(socket: socket)
        @requests << request
        response = @replies.pop
        response[:body] = response[:body].call(request) if response[:body].respond_to?(:call)
        write_response(socket: socket, response: response)
      rescue Errno::EPIPE, Errno::ECONNRESET
        Legion::Logging.debug('Local ChatGPT fixture client disconnected')
      ensure
        socket.close
      end
    end
  end

  def read_request(socket:)
    request_line = socket.gets("\r\n")
    headers = {}
    while (line = socket.gets("\r\n")) && line != "\r\n"
      key, value = line.split(':', 2)
      headers[key.downcase] = value.strip
    end
    body = socket.read(headers.fetch('content-length', '0').to_i)
    { path: request_line.split[1], headers: headers, body: body }
  end

  def write_response(socket:, response:)
    socket.write("HTTP/1.1 #{response[:status]} Fixture\r\nContent-Type: #{response[:content_type]}\r\n" \
                 "Transfer-Encoding: chunked\r\nConnection: close\r\n")
    response[:headers].each { |key, value| socket.write("#{key}: #{value}\r\n") }
    socket.write("\r\n")
    response[:body].bytes.each_slice(7) do |bytes|
      part = bytes.pack('C*')
      socket.write("#{part.bytesize.to_s(16)}\r\n#{part}\r\n")
    end
    socket.write("0\r\n\r\n")
  end
end
