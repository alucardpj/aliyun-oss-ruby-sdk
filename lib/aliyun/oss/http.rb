# -*- encoding: utf-8 -*-

require 'rest-client'
require 'fiber'

module Aliyun
  module OSS

    ##
    # HTTP wraps the HTTP functionalities for accessing OSS RESTful
    # API. It handles the OSS-specific protocol elements, and
    # rest-client details for the user, which includes:
    # * automatically generate signature for every request
    # * parse response headers/body
    # * raise exceptions and capture the request id
    # * encapsulates streaming upload/download
    # @example simple get
    #   headers, body = http.get({:bucket => 'bucket'})
    # @example streaming download
    #   http.get({:bucket => 'bucket', :object => 'object'}) do |chunk|
    #     # handle chunk
    #   end
    # @example streaming upload
    #   def streaming_upload(&block)
    #     http.put({:bucket => 'bucket', :object => 'object'},
    #              {:body => HTTP::StreamPlayload.new(block)})
    #   end
    #
    #   streaming_upload do |stream|
    #     stream << "hello world"
    #   end
    class HTTP

      DEFAULT_CONTENT_TYPE = 'application/octet-stream'
      STS_HEADER = 'x-oss-security-token'
      OPEN_TIMEOUT = 10
      READ_TIMEOUT = 120

      ##
      # A stream implementation
      # A stream is any class that responds to :read(bytes, outbuf)
      #
      class StreamWriter
        def initialize
          @buffer = ""
          @producer = Fiber.new { yield self if block_given? }
          @producer.resume
        end

        def read(bytes = nil, outbuf = nil)
          ret = ""
          loop do
            if bytes
              ret << @buffer.slice!(0, bytes)
              break if ret.size >= bytes
            else
              ret << @buffer
              @buffer.clear
            end

            if @producer.alive?
              @producer.resume
            else
              break
            end
          end

          if outbuf
            # WARNING: Using outbuf = '' here DOES NOT work!
            outbuf.clear
            outbuf << ret
          end

          # Conform to IO#read(length[, outbuf]):
          # At end of file, it returns nil or "" depend on
          # length. ios.read() and ios.read(nil) returns
          # "". ios.read(positive-integer) returns nil.
          return nil if ret.empty? && !bytes.nil? && bytes > 0

          ret
        end

        def write(chunk)
          @buffer << chunk.to_s.force_encoding(Encoding::ASCII_8BIT)
          Fiber.yield
          self
        end

        alias << write

        def closed?
          false
        end

        def inspect
          "@buffer: " + @buffer[0, 32].inspect + "...#{@buffer.size} bytes"
        end
      end

      # RestClient requires the payload to respones to :read(bytes)
      # and return a stream.
      # We are not doing the real read here, just return a
      # readable stream for RestClient playload.rb treats it as:
      #     def read(bytes=nil)
      #       @stream.read(bytes)
      #     end
      #     alias :to_s :read
      #     net_http_do_request(http, req, payload ? payload.to_s : nil,
      #                     &@block_response)
      class StreamPayload
        def initialize(&block)
          @stream = StreamWriter.new(&block)
        end

        def read(bytes = nil)
          @stream
        end

        def close
        end

        def closed?
          false
        end

      end

      include Common::Logging

      def initialize(config)
        @config = config
      end

      def get_request_url(bucket, object)
        url = ""
        url += "#{@config.endpoint.scheme}://"
        url += "#{bucket}." if bucket and not @config.cname
        url += @config.endpoint.host
        url += "/#{CGI.escape(object)}" if object

        url
      end

      def get_resource_path(bucket, object)
        if bucket
          res = "/#{bucket}/"
          res += "#{object}" if object
          res
        end
      end

      # Handle Net::HTTPRespoonse
      def handle_response(r, &block)
        # read all body on error
        if r.code.to_i >= 300
          r.read_body
        else
        # streaming read body on success
          r.read_body do |chunk|
            yield RestClient::Request.decode(r['content-encoding'], chunk)
          end
        end
      end

      ##
      # helper methods
      #
      def get(resources = {}, http_options = {}, &block)
        do_request('GET', resources, http_options, &block)
      end

      def put(resources = {}, http_options = {}, &block)
        do_request('PUT', resources, http_options, &block)
      end

      def post(resources = {}, http_options = {}, &block)
        do_request('POST', resources, http_options, &block)
      end

      def delete(resources = {}, http_options = {}, &block)
        do_request('DELETE', resources, http_options, &block)
      end

      def head(resources = {}, http_options = {}, &block)
        do_request('HEAD', resources, http_options, &block)
      end

      def options(resources = {}, http_options = {}, &block)
        do_request('OPTIONS', resources, http_options, &block)
      end

      private
      # Do HTTP reqeust
      # @param verb [String] HTTP Verb: GET/PUT/POST/DELETE/HEAD/OPTIONS
      # @param resources [Hash] OSS related resources
      # @option resources [String] :bucket the bucket name
      # @option resources [String] :object the object name
      # @option resources [Hash] :sub_res sub-resources
      # @param http_options [Hash] HTTP options
      # @option http_options [Hash] :headers HTTP headers
      # @option http_options [Hash] :query HTTP queries
      # @option http_options [Object] :body HTTP body, may be String
      #  or Stream
      def do_request(verb, resources = {}, http_options = {}, &block)
        bucket = resources[:bucket]
        object = resources[:object]
        sub_res = resources[:sub_res]

        headers = http_options[:headers] || {}
        headers['User-Agent'] = get_user_agent
        headers['Date'] = Time.now.httpdate
        headers['Content-Type'] ||= DEFAULT_CONTENT_TYPE
        headers[STS_HEADER] = @config.sts_token if @config.sts_token

        if body = http_options[:body]
          if body.respond_to?(:read)
            headers['Transfer-Encoding'] = 'chunked'
          else
            headers['Content-MD5'] = Util.get_content_md5(body)
          end
        end

        res = {
          :path => get_resource_path(bucket, object),
          :sub_res => sub_res,
        }

        if @config.access_key_id and @config.access_key_secret
          sig = Util.get_signature(@config.access_key_secret, verb, headers, res)
          headers['Authorization'] = "OSS #{@config.access_key_id}:#{sig}"
        end

        logger.debug("Send HTTP request, verb: #{verb}, resources: " \
                      "#{resources}, http options: #{http_options}")

        # From rest-client:
        # "Due to unfortunate choices in the original API, the params
        # used to populate the query string are actually taken out of
        # the headers hash."
        headers[:params] = (sub_res || {}).merge(http_options[:query] || {})

        block_response = ->(r) { handle_response(r, &block) } if block
        r = RestClient::Request.execute(
          :method => verb,
          :url => get_request_url(bucket, object),
          :headers => headers,
          :payload => http_options[:body],
          :block_response => block_response,
          :open_timeout => @config.open_timeout || OPEN_TIMEOUT,
          :timeout => @config.read_timeout || READ_TIMEOUT
        ) do |response, request, result, &blk|

          if response.code >= 300
            e = ServerError.new(response)
            logger.error(e.to_s)
            raise e
          else
            response.return!(request, result, &blk)
          end
        end

        # If streaming read_body is used, we need to create the
        # RestClient::Response ourselves
        unless r.is_a?(RestClient::Response)
          if r.code.to_i >= 300
            r = RestClient::Response.create(
              RestClient::Request.decode(r['content-encoding'], r.body),
              r, nil, nil)
            e = ServerError.new(r)
            logger.error(e.to_s)
            raise e
          end
          r = RestClient::Response.create(nil, r, nil, nil)
          r.return!
        end

        logger.debug("Received HTTP response, code: #{r.code}, headers: " \
                      "#{r.headers}, body: #{r.body}")

        r
      end

      def get_user_agent
        "aliyun-sdk-ruby/#{VERSION} ruby-#{RUBY_VERSION}/#{RUBY_PLATFORM}"
      end

    end # HTTP
  end # OSS
end # Aliyun

# Monkey patch rest-client to exclude the 'Content-Length' header when
# 'Transfer-Encoding' is set to 'chuncked'. This may be a problem for
# some http servers like tengine.
module RestClient
  module Payload
    class Base
      def headers
        ({'Content-Length' => size.to_s} if size) || {}
      end
    end
  end
end
