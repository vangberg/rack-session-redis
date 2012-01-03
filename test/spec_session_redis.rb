require 'thread'
require 'redis'
require 'rack/mock'
require 'rack/session/redis'

describe Rack::Session::Redis do
  session_key = Rack::Session::Redis::DEFAULT_OPTIONS[:key]
  session_match = /#{session_key}=[0-9a-fA-F]+;/

  incrementor = lambda do |env|
    env["rack.session"]["counter"] ||= 0
    env["rack.session"]["counter"] += 1
    Rack::Response.new(env["rack.session"].inspect).to_a
  end

  drop_session = lambda do |env|
    env['rack.session.options'][:drop] = true
    incrementor.call(env)
  end

  renew_session = lambda do |env|
    env['rack.session.options'][:renew] = true
    incrementor.call(env)
  end

  defer_session = lambda do |env|
    env['rack.session.options'][:defer] = true
    incrementor.call(env)
  end

  do_nothing = lambda do |env|
    env['rack.session']['bob'] # fetch any key, just to load the session
    Rack::Response.new(env["rack.session"].inspect).to_a
  end

  delete_key = lambda do |env|
    env['rack.session'].delete('counter')
    do_nothing.call(env)
  end

  before do
    @redis = Redis.new
    @redis.flushdb
  end

  it "creates a new cookie" do
    app = Rack::Session::Redis.new(incrementor)
    res = Rack::MockRequest.new(app).get("/")
    res["Set-Cookie"].should.match session_match
    res.body.should.equal '{"counter"=>1}'
  end

  it "determines session from a cookie" do
    app = Rack::Session::Redis.new(incrementor)
    req = Rack::MockRequest.new(app)
    cookie = req.get("/")["Set-Cookie"]
    req.get("/", "HTTP_COOKIE" => cookie).
      body.should.equal '{"counter"=>2}'
    req.get("/", "HTTP_COOKIE" => cookie).
      body.should.equal '{"counter"=>3}'
  end

  it "survives nonexistant cookies" do
    app = Rack::Session::Redis.new(incrementor)
    res = Rack::MockRequest.new(app).
      get("/", "HTTP_COOKIE" => "#{session_key}=blarghfasel")
    res.body.should.equal '{"counter"=>1}'
  end

  it "deletes cookies with :drop option" do
    app = Rack::Session::Redis.new(incrementor)
    req = Rack::MockRequest.new(app)
    drop = Rack::Utils::Context.new(app, drop_session)
    dreq = Rack::MockRequest.new(drop)

    res0 = req.get("/")
    session = (cookie = res0["Set-Cookie"])[session_match]
    res0.body.should.equal '{"counter"=>1}'
    app.redis.dbsize.should.equal 1

    res1 = req.get("/", "HTTP_COOKIE" => cookie)
    res1.body.should.equal '{"counter"=>2}'
    app.redis.dbsize.should.equal 1

    res2 = dreq.get("/", "HTTP_COOKIE" => cookie)
    res2["Set-Cookie"].should.equal nil
    res2.body.should.equal '{"counter"=>3}'
    app.redis.dbsize.should.equal 0

    res3 = req.get("/", "HTTP_COOKIE" => cookie)
    res3["Set-Cookie"][session_match].should.not.equal session
    res3.body.should.equal '{"counter"=>1}'
    app.redis.dbsize.should.equal 1
  end

  it "provides new session id with :renew option" do
    app = Rack::Session::Redis.new(incrementor)
    req = Rack::MockRequest.new(app)
    renew = Rack::Utils::Context.new(app, renew_session)
    rreq = Rack::MockRequest.new(renew)

    res0 = req.get("/")
    session = (cookie = res0["Set-Cookie"])[session_match]
    res0.body.should.equal '{"counter"=>1}'
    app.redis.dbsize.should.equal 1

    res1 = req.get("/", "HTTP_COOKIE" => cookie)
    res1.body.should.equal '{"counter"=>2}'
    app.redis.dbsize.should.equal 1

    res2 = rreq.get("/", "HTTP_COOKIE" => cookie)
    new_cookie = res2["Set-Cookie"]
    new_session = new_cookie[session_match]
    new_session.should.not.equal session
    res2.body.should.equal '{"counter"=>3}'
    app.redis.dbsize.should.equal 1

    res3 = req.get("/", "HTTP_COOKIE" => new_cookie)
    res3.body.should.equal '{"counter"=>4}'
    app.redis.dbsize.should.equal 1
  end

  it "omits cookie with :defer option" do
    app = Rack::Session::Redis.new(incrementor)
    req = Rack::MockRequest.new(app)
    defer = Rack::Utils::Context.new(app, defer_session)
    dreq = Rack::MockRequest.new(defer)

    res0 = req.get("/")
    session = (cookie = res0["Set-Cookie"])[session_match]
    res0.body.should.equal '{"counter"=>1}'
    app.redis.dbsize.should.equal 1

    res1 = req.get("/", "HTTP_COOKIE" => cookie)
    res1.body.should.equal '{"counter"=>2}'
    app.redis.dbsize.should.equal 1

    res2 = dreq.get("/", "HTTP_COOKIE" => cookie)
    res2["Set-Cookie"].should.equal nil
    res2.body.should.equal '{"counter"=>3}'
    app.redis.dbsize.should.equal 1

    res3 = req.get("/", "HTTP_COOKIE" => cookie)
    res3.body.should.equal '{"counter"=>4}'
    app.redis.dbsize.should.equal 1
  end

  it "should delete values from the session correctly" do
    app = Rack::Session::Redis.new(incrementor)
    req = Rack::MockRequest.new(app)

    key_deletor = Rack::Utils::Context.new(app, delete_key)
    kdreq = Rack::MockRequest.new(key_deletor)

    nothing = Rack::Utils::Context.new(app, do_nothing)
    nothing_req = Rack::MockRequest.new(nothing)

    res0 = req.get("/")
    cookie = req.get("/")["Set-Cookie"]

    res1 = kdreq.get("/", "HTTP_COOKIE" => cookie)
    res1.body.should.equal '{}'

    res2 = nothing_req.get("/", "HTTP_COOKIE" => cookie)
    res2.body.should.equal '{}'
  end

  # anyone know how to do this better?
  it "should merge sessions when multithreaded" do
    unless $DEBUG
      1.should.equal 1
      next
    end

    warn 'Running multithread tests for Session::Redis'
    app = Rack::Session::Redis.new(incrementor)
    req = Rack::MockRequest.new(app)

    res = req.get('/')
    res.body.should.equal '{"counter"=>1}'
    cookie = res["Set-Cookie"]
    sess_id = cookie[/#{app.key}=([^,;]+)/,1]

    delta_incrementor = lambda do |env|
      # emulate disconjoinment of threading
      env['rack.session'] = env['rack.session'].dup
      Thread.stop
      env['rack.session'][(Time.now.usec*rand).to_i] = true
      incrementor.call(env)
    end
    tses = Rack::Utils::Context.new app, delta_incrementor
    treq = Rack::MockRequest.new(tses)
    tnum = rand(7).to_i+5
    r = Array.new(tnum) do
      Thread.new(treq) do |run|
        run.get('/', "HTTP_COOKIE" => cookie, 'rack.multithread' => true)
      end
    end.reverse.map{|t| t.run.join.value }
    r.each do |res|
      res['Set-Cookie'].should.equal cookie
      res.body.should.include '"counter"=>2'
    end

    session = app.redis[sess_id]
    session.size.should.equal tnum+1 # counter
    session['counter'].should.equal 2 # meeeh
  end

  it "namespaces redis keys" do
    app = Rack::Session::Redis.new(incrementor, :namespace => "test:space")
    res = Rack::MockRequest.new(app).get("/")
    @redis.keys("test:space:*").size.should.equal 1
  end

  it "maintains freshness" do
    app = Rack::Session::Redis.new(incrementor, :expire_after => 2)
    res = Rack::MockRequest.new(app).get('/')
    res.body.should.include '"counter"=>1'
    cookie = res["Set-Cookie"]
    res = Rack::MockRequest.new(app).get('/', "HTTP_COOKIE" => cookie)
    res["Set-Cookie"].should.equal cookie
    res.body.should.include '"counter"=>2'
    puts 'Sleeping to expire session' if $DEBUG
    sleep 3
    res = Rack::MockRequest.new(app).get('/', "HTTP_COOKIE" => cookie)
    res["Set-Cookie"].should.not.equal cookie
    res.body.should.include '"counter"=>1'
  end
end
