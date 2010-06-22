Gem::Specification.new do |s|
  s.name     = "rack-session-redis"
  s.version  = "0.0.1"
  s.date     = "2010-06-22"
  s.summary  = "redis session store for rack"
  s.email    = "harry@vangberg.name"
  s.homepage = "http://github.com/ichverstehe/rack-session-redis"
  s.description = "redis session store for rack"
  s.authors  = ["Harry Vangberg"]
  s.files    = [
    "README",
		"rack-session-redis.gemspec", 
		"lib/rack/session/redis.rb",
  ]
  s.add_dependency "redis", ">= 2.0.0"
end

