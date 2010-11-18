require 'json'
require 'socket'
require 'stringio'

module Nack
  class Server
    SERVER_ERROR = [500, { "Content-Type" => "text/html" }, ["Internal Server Error"]]
    BAD_REQUEST  = [400, { "Content-Type" => "text/html" }, ["Bad Request"]]

    def self.run(*args)
      new(*args).start
    end

    attr_accessor :app, :host, :port, :file, :pipe
    attr_accessor :name, :request_count

    def initialize(app, options = {})
      # Lazy require rack
      require 'rack'

      self.app = app

      self.host = options[:host]
      self.port = options[:port]
      self.file = options[:file]

      self.pipe = options[:pipe]

      self.name = options[:name] || "app"
      self.request_count = 0
    end

    def open_server
      if file
        File.unlink(file) if File.exist?(file)
        UNIXServer.open(file)
      elsif port
        TCPServer.open(port)
      else
        raise Error, "no socket given"
      end
    end

    def start
      server = open_server

      close = proc do
        server.close

        File.unlink(file) if file && File.exist?(file)
        File.unlink(pipe) if pipe && File.exist?(pipe)
      end

      trap('TERM') { debug "Received TERM"; close.call(); exit! 0 }
      trap('INT')  { debug "Received INT"; close.call(); exit! 0 }
      trap('QUIT') { debug "Received QUIT"; close.call() }

      listeners = [server]
      buffers = {}

      if pipe
        a = open(pipe, 'w')
        a.write $$.to_s
        a.close
      end

      loop do
        $0 = "nack worker [#{name}] (#{request_count})"
        debug "Waiting for connection"

        readable, writable = IO.select(listeners, nil, nil, 60)

        if server.closed?
          break
        end

        next unless readable

        readable.each do |sock|
          if sock == server
            listeners << server.accept_nonblock
          else
            client, buf = sock, buffers[sock] ||= ''

            begin
              buf << client.read_nonblock(1024)
            rescue EOFError
              handle sock, StringIO.new(buf)
              buffers.delete(client)
              listeners.delete(client)
            end
          end
        end
      end

      nil
    end

    def handle(sock, buf)
      self.request_count += 1
      debug "Accepted connection"

      status, headers, body = SERVER_ERROR

      env, input = nil, StringIO.new
      begin
        NetString.read(buf) do |data|
          if env.nil?
            env = JSON.parse(data)
          elsif data.length > 0
            input.write(data)
          else
            break
          end
        end
      rescue Nack::Error, JSON::ParserError
      end

      sock.close_read
      input.rewind

      if env
        method, path = env['REQUEST_METHOD'], env['PATH_INFO']
        debug "Received request: #{method} #{path}"
        $0 = "nack worker [#{name}] (#{request_count}) #{method} #{path}"

        env = env.merge({
          "rack.version" => Rack::VERSION,
          "rack.input" => input,
          "rack.errors" => $stderr,
          "rack.multithread" => false,
          "rack.multiprocess" => true,
          "rack.run_once" => false,
          "rack.url_scheme" => ["yes", "on", "1"].include?(env["HTTPS"]) ? "https" : "http"
        })

        begin
          status, headers, body = app.call(env)
        rescue Exception => e
          warn "#{e.class}: #{e.message}"
          warn e.backtrace.join("\n")
          status, headers, body = SERVER_ERROR
        end
      else
        debug "Received bad request"
        status, headers, body = BAD_REQUEST
      end

      begin
        debug "Sending response: #{status}"
        NetString.write(sock, status.to_s)
        NetString.write(sock, headers.to_json)

        body.each do |part|
          NetString.write(sock, part) if part.length > 0
        end
        NetString.write(sock, "")
      ensure
        body.close if body.respond_to?(:close)
      end
    rescue Exception => e
      warn "#{e.class}: #{e.message}"
      warn e.backtrace.join("\n")
    ensure
      sock.close_write
    end

    def debug(msg)
      warn msg if $DEBUG
    end
  end
end
