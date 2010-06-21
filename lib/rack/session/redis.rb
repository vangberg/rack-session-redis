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
        def get(key)
          raw = super
          Marshal.load(raw) if raw
        end

        def set key, value
          raw = Marshal.dump(value)
          super(key, raw)
        end
      end

      attr_reader :mutex, :redis
      DEFAULT_OPTIONS = Abstract::ID::DEFAULT_OPTIONS.merge :drop => false

      def initialize(app, options={})
        super
        @redis = MarshalledRedis.new
        @mutex = Mutex.new
      end

      def generate_sid
        loop do
          sid = super
          break sid unless @redis.exists(sid)
        end
      end

      def get_session(env, sid)
        session = @redis.get(sid) if sid
        @mutex.lock if env['rack.multithread']
        unless sid and session
          env['rack.errors'].puts("Session '#{sid.inspect}' not found, initializing...") if $VERBOSE and not sid.nil?
          session = {}
          sid = generate_sid
          @redis.set sid, session
        end
        session.instance_variable_set('@old', {}.merge(session))
        return [sid, session]
      ensure
        @mutex.unlock if env['rack.multithread']
      end

      def set_session(env, session_id, new_session, options)
        @mutex.lock if env['rack.multithread']
        session = @redis.get(session_id)
        if options[:renew] or options[:drop]
          @redis.del session_id
          return false if options[:drop]
          session_id = generate_sid
          @redis.set session_id, 0
        end
        old_session = new_session.instance_variable_get('@old') || {}
        session = merge_sessions session_id, old_session, new_session, session
        @redis.set session_id, session
        return session_id
      rescue => e
        warn "#{new_session.inspect} has been lost."
        warn $!.inspect
      ensure
        @mutex.unlock if env['rack.multithread']
      end

      private

      def merge_sessions sid, old, new, cur=nil
        cur ||= {}
        unless Hash === old and Hash === new
          warn 'Bad old or new sessions provided.'
          return cur
        end

        delete = old.keys - new.keys
        warn "//@#{sid}: dropping #{delete*','}" if $DEBUG and not delete.empty?
        delete.each{|k| cur.delete k }

        update = new.keys.select{|k| new[k] != old[k] }
        warn "//@#{sid}: updating #{update*','}" if $DEBUG and not update.empty?
        update.each{|k| cur[k] = new[k] }

        cur
      end
    end
  end
end
