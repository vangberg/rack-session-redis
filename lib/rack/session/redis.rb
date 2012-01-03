# AUTHOR: blink <blinketje@gmail.com>; blink#ruby-lang@irc.freenode.net
# THANKS:
#   apeiros, for session id generation, expiry setup, and threadiness
#   sergio, threadiness and bugreps

require 'rack/session/abstract/id'
require 'redis'
require 'thread'

module Rack
  module Session

    class Redis < Abstract::ID
      class MarshalledRedis < ::Redis
        def initialize options={}
          @namespace = options.delete(:namespace)

          super
        end

        def get key
          raw = super namespace(key)
          Marshal.load raw if raw
        end

        def set key, value
          raw = Marshal.dump value
          super namespace(key), raw
        end

        def del key
          super namespace(key)
        end

        def setex key, time, value
          raw = Marshal.dump value
          super namespace(key), time, raw
        end

        private
        def namespace key
          @namespace ? "#{@namespace}:#{key}" : key
        end
      end

      attr_reader :mutex, :redis
      DEFAULT_OPTIONS = Abstract::ID::DEFAULT_OPTIONS.merge(
        :drop      => false,
        :url       => "redis://127.0.0.1:6379/0",
        :namespace => "rack:session"
      )

      def initialize(app, options={})
        super

        @redis     = MarshalledRedis.connect(
          :namespace => default_options[:namespace],
          :url       => default_options[:url]
        )
        @mutex     = Mutex.new
      end

      def generate_sid
        loop do
          sid = super
          break sid unless @redis.exists(sid)
        end
      end

      def get_session(env, sid)
        with_lock(env, [nil, {}]) do
          unless sid and session = @redis.get(sid)
            sid, session = generate_sid, {}
            unless @redis.set(sid, session)
              raise "Session collision on '#{sid.inspect}'"
            end
          end
          [sid, session]
        end
      end

      def set_session(env, session_id, new_session, options)
        with_lock(env, false) do
  
          if options[:renew] or options[:drop]
            @redis.del session_id
            return false if options[:drop]

            session_id = generate_sid
          end

          if options[:expire_after].to_i > 0
            @redis.setex session_id, options[:expire_after], new_session
          else
            @redis.set session_id, new_session
          end
          session_id
        end
      end

      def destroy_session(env, session_id, options)
        options = { :renew => true }.update(options) unless options[:drop]
        set_session(env, session_id, 0, options)
      end

      def with_lock(env, default=nil)
        @mutex.lock if env['rack.multithread']
        yield
      rescue Errno::ECONNREFUSED
        if $VERBOSE
          warn "#{self} is unable to find redis server."
          warn $!.inspect
        end
        default
      ensure
        @mutex.unlock if @mutex.locked?
      end

    end
  end
end
