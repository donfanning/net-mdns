=begin
  Copyright (C) 2005 Sam Roberts

  This library is free software; you can redistribute it and/or modify it
  under the same terms as the ruby language itself, see the file COPYING for
  details.
=end

require 'ipaddr'
require 'logger'
require 'singleton'

require 'net/dns/resolvx'

BasicSocket.do_not_reverse_lookup = true

module Net
  module DNS

    Message      = Resolv::DNS::Message
    Name         = Resolv::DNS::Name
    DecodeError  = Resolv::DNS::DecodeError

    module IN
      A      = Resolv::DNS::Resource::IN::A
      AAAA   = Resolv::DNS::Resource::IN::AAAA
      ANY    = Resolv::DNS::Resource::IN::ANY
      CNAME  = Resolv::DNS::Resource::IN::CNAME
      HINFO  = Resolv::DNS::Resource::IN::HINFO
      MINFO  = Resolv::DNS::Resource::IN::MINFO
      MX     = Resolv::DNS::Resource::IN::MX
      NS     = Resolv::DNS::Resource::IN::NS
      PTR    = Resolv::DNS::Resource::IN::PTR
      SOA    = Resolv::DNS::Resource::IN::SOA
      SRV    = Resolv::DNS::Resource::IN::SRV
      TXT    = Resolv::DNS::Resource::IN::TXT
      WKS    = Resolv::DNS::Resource::IN::WKS
    end

    # Returns the resource record name of +rr+ as a short string ("IN::A",
    # ...).
    def self.rrname(rr)
      rr = rr.class unless rr.class == Class
      rr = rr.to_s.sub(/.*Resource::/, '')
      rr = rr.to_s.sub(/.*DNS::/, '')
    end

    module MDNS
      class Answer
        attr_reader :name, :ttl, :data
        # TOA - time of arrival (of an answer)
        attr_reader :toa
        attr_accessor :retries

        def initialize(name, ttl, data)
          @name = name
          @ttl = ttl
          @data = data
          @toa = Time.now.to_i
          @retries = 0
        end

        def type
          data.class
        end

        def refresh
          # Percentage points are from mDNS
          percent = [80,85,90,95][retries]

          # TODO - add a 2% of TTL jitter
          toa + ttl * percent / 100 if percent
        end

        def expiry
          toa + (ttl == 0 ? 1 : ttl)
        end

        def expired?
          true if Time.now.to_i > expiry
        end

        def absolute?
          @data.cacheflush?
        end

        def to_s
          s = "#{name.to_s} (#{ttl}) "
          s << '!' if absolute?
          s << '-' if ttl == 0
          s << " #{DNS.rrname(data)}"

          case data
          when IN::A
            s << " #{data.address.to_s}"
          when IN::PTR
            s << " #{data.name}"
          when IN::SRV
            s << " #{data.target}:#{data.port}"
          when IN::TXT
            s << " #{data.strings.first.inspect}#{data.strings.length > 1 ? ', ...' : ''}"
          when IN::HINFO
            s << " os=#{data.os}, cpu=#{data.cpu}"
          else
            s << data.inspect
          end
          s
        end
      end

      class Question
        attr_reader :name, :type, :retries
        attr_writer :retries

        # Normally we see our own question, so an update will occur right away,
        # causing retries to be set to 1. If we don't see our own question, for
        # some reason, we'll ask again a second later.
        RETRIES = [1, 1, 2, 4]

        def initialize(name, type)
          @name = name
          @type = type

          @lastq = Time.now.to_i

          @retries = 0
        end

        # Update the number of times the question has been asked based on having
        # seen the question, so that the question is considered asked whether
        # we asked it, or another machine/process asked.
        def update
          @retries += 1
          @lastq = Time.now.to_i
        end

        # Questions are asked 4 times, repeating at increasing intervals of 1,
        # 2, and 4 seconds.
        def refresh
          r = RETRIES[retries]
          @lastq + r if r
        end

        def to_s
          "#{@name.to_s}/#{DNS.rrname @type} (#{@retries})"
        end
      end

      class Cache
        # asked: Hash[Name] -> Hash[Resource] -> Question
        attr_reader :asked

        # cached: Hash[Name] -> Hash[Resource] -> Array -> Answer
        attr_reader :cached

        def initialize
          @asked = Hash.new { |h,k| h[k] = Hash.new }

          @cached = Hash.new { |h,k| h[k] = (Hash.new { |a,b| a[b] = Array.new }) }
        end

        # Return the question if we added it, or nil if question is already being asked.
        def add_question(qu)
          if qu && !@asked[qu.name][qu.type]
            @asked[qu.name][qu.type] = qu
          end
        end

        # Cache question. Increase the number of times we've seen it.
        def cache_question(name, type)
          if qu = @asked[name][type]
            qu.update
          end
          qu
        end

        # Return cached answer, or nil if answer wasn't cached.
        def cache_answer(an)
          answers = @cached[an.name][an.type]

          if( an.absolute? )
            # Replace all answers older than a ~1 sec [mDNS].
            # If the data is the same, don't delete it, we don't want it to look new.
            now_m1 = Time.now.to_i - 1
            answers.delete_if { |a| a.toa < now_m1 && a.data != an.data }
          end

          old_an = answers.detect { |a| a.name == an.name && a.data == an.data }

          if( !old_an )
            # new answer, cache it
            answers << an
          elsif( an.ttl == 0 )
            # it's a "remove" notice, replace old_an
            answers.delete( old_an )
            answers << an
          elsif( an.expiry > old_an.expiry)
            # it's a fresher record than we have, cache it but the data is the
            # same so don't report it as cached
            answers.delete( old_an )
            answers << an
            an = nil
          else
            # don't cache it
            an = nil
          end

          an
        end

        def answers_for(name, type)
          answers = []
          if( name.to_s == '*' )
            @cached.keys.each { |n| answers += answers_for(n, type) }
          elsif( type == IN::ANY )
            @cached[name].each { |rtype,rdata| answers += rdata }
          else
            answers += @cached[name][type]
          end
          answers
        end

        def asked?(name, type)
          return true if name.to_s == '*'

          t = @asked[name][type] || @asked[name][IN::ANY]

          # TODO - true if (Time.now - t) < some threshold...

          t
        end

      end

      class Responder
        include Singleton

        # mDNS link-local multicast address
        Addr = "224.0.0.251"
        Port = 5353
        UDPSize = 9000

        attr_reader :cache
        attr_reader :log

        # Log messages to +log+. +log+ must be +nil+ (no logging) or an object
        # that responds to debug(), warn(), and error(). Default is a Logger to
        # STDERR that logs only ERROR messages.
        def log=(log)
          unless !log || (log.respond_to?(:debug) && log.respond_to?(:warn) && log.respond_to?(:error))
            raise ArgumentError, "log doesn't appear to be a kind of logger"
          end
          @log = log
        end

        def debug(*args)
          @log.debug( *args ) if @log
        end
        def warn(*args)
          @log.warn( *args ) if @log
        end
        def error(*args)
          @log.error( *args ) if @log
        end

        def initialize
          @log = Logger.new(STDERR)

          @log.level = Logger::ERROR

          @mutex = Mutex.new

          @cache = Cache.new

          @queries = []

          @services = []

          debug( "start" )

          # TODO - I'm not sure about how robust this is. A better way to find the default
          # ifx would be to do:
          #   s = UDPSocket.new
          #   s.connect(any addr, any port)
          #   s.getsockname => struct sockaddr_in => ip_addr
          # But parsing a struct sockaddr_in is a PITA in ruby.

          kINADDR_IFX = Socket.gethostbyname(Socket.gethostname)[3]

          @sock = UDPSocket.new

          # TODO - do we need this?
          @sock.fcntl(Fcntl::F_SETFD, 1)

          # Allow 5353 to be shared.
          so_reuseport = 0x0200 # The definition on OS X, where it is required.
          if Socket.constants.include? 'SO_REUSEPORT'
            so_reuseport = Socket::SO_REUSEPORT
          end
          begin
            @sock.setsockopt(Socket::SOL_SOCKET, so_reuseport, 1)
          rescue
            warn( "set SO_REUSEPORT raised #{$!}, try SO_REUSEADDR" )
            @sock.setsockopt(Socket::SOL_SOCKET,Socket::SO_REUSEADDR, 1)
          end

          # Request dest addr and ifx ids... no.

          # Join the multicast group.
          #  option is a struct ip_mreq { struct in_addr, struct in_addr }
          ip_mreq =  IPAddr.new(Addr).hton + kINADDR_IFX
          @sock.setsockopt(Socket::IPPROTO_IP, Socket::IP_ADD_MEMBERSHIP, ip_mreq)
          @sock.setsockopt(Socket::IPPROTO_IP, Socket::IP_MULTICAST_IF, kINADDR_IFX)

          # Set IP TTL for outgoing packets.
          @sock.setsockopt(Socket::IPPROTO_IP, Socket::IP_TTL, 255)
          @sock.setsockopt(Socket::IPPROTO_IP, Socket::IP_MULTICAST_TTL, 255)

          # Apple source makes it appear that optval may need to be a "char" on
          # some systems:
          #  @sock.setsockopt(Socket::IPPROTO_IP, Socket::IP_MULTICAST_TTL, 255 as int)
          #     - or -
          #  @sock.setsockopt(Socket::IPPROTO_IP, Socket::IP_MULTICAST_TTL, 255 as byte)

          # Bind to our port.
          @sock.bind(Socket::INADDR_ANY, Port)

          # Start responder and cacher threads.

          @waketime = nil

          @cacher_thrd = Thread.new do
            begin
              cacher_loop
            rescue
              error( "cacher_loop exited with #{$!}" )
              $!.backtrace.each do |e| error(e) end
            end
          end

          @responder_thrd = Thread.new do
            begin
              responder_loop
            rescue
              error( "responder_loop exited with #{$!}" )
              $!.backtrace.each do |e| error(e) end
            end
          end
        end

        def responder_loop
          loop do
            # from is [ AF_INET, port, name, addr ]
            reply, from = @sock.recvfrom(UDPSize)

            @mutex.synchronize do

              begin
                msg =  Message.decode(reply)

                debug( "from #{from[3]}:#{from[1]} -> qr=#{msg.qr} qcnt=#{msg.question.size} acnt=#{msg.answer.size}" )

                if( msg.query? )
                  # Cache questions:
                  # - ignore unicast queries
                  # - record the question as asked
                  # - TODO flush any answers we have over 1 sec old (otherwise if a machine goes down, its
                  #    answers stay until there ttl, which can be very long!)
                  msg.each_question do |name, type|
                    next if (type::ClassValue >> 15) == 1

                    debug( "++ q #{name.to_s}/#{DNS.rrname(type)}" )

                    @cache.cache_question(name, type)
                  end

                  # Answer questions for registered services:
                  # - let each service add any records that answer the question
                  # - send an answer if there are any answers
                  amsg = Message.new(0)
                  amsg.qr = 1
                  msg.each_question do |name, type|
                    debug( "ask? #{name}/#{DNS.rrname(type)}" )
                    @services.each do |svc|
                      svc.answer_question(name, type, amsg)
                    end
                  end
                  if amsg.answer.first
                    amsg.answer.each do |an|
                      debug( "-> a #{an[0]} (#{an[1]}) #{an[2].to_s}" )
                    end
                    send(amsg)
                  end

                else
                  # Cache answers:
                  cached = []
                  msg.each_answer do |n, ttl, data|

                    a = Answer.new(n, ttl, data)
                    debug( "++ a #{ a }" )
                    a = @cache.cache_answer(a)
                    debug( " cached" ) if a

                    # If a wasn't cached, then its an answer we already have, don't push it.
                    cached << a if a

                    wake_cacher_for(a)
                  end

                  # Push answers to Queries:
                  # TODO - push all answers, let the Query do what it wants with them.
                  @queries.each do |q|
                    answers = cached.select { |an| q.subscribes_to? an }

                    debug( "push #{answers.length} to #{q}" )

                    q.push( *answers )
                  end

                end

              rescue DecodeError
                warn( "decode error: #{reply.inspect}" )
              end

            end # end sync
          end # end loop
        end

        # wake sweeper if cache item needs refreshing before current waketime
        def wake_cacher_for(item)
          return unless item

          if !@waketime || @waketime == 0 || item.refresh < @waketime
            @cacher_thrd.wakeup
          end
        end

        def cacher_loop
          delay = 0

          loop do

            if delay > 0
              sleep(delay)
            else
              sleep
            end

            @mutex.synchronize do
              debug( "sweep begin" )

              @waketime = nil

              msg = Message.new(0)

              now = Time.now.to_i

              # the earliest question or answer we need to wake for
              wakefor = nil

              # TODO - A delete expired, that yields every answer before
              # deleting it (so I can log it).
              # TODO - A #each_answer?
              @cache.cached.each do |name,rtypes|
                rtypes.each do |rtype, answers|
                  # Delete expired answers.
                  answers.delete_if do |an|
                    if an.expired?
                      debug( "-- a #{an}" )
                      true
                    end
                  end
                  # Requery answers that need refreshing, if there is a query that wants it.
                  # Remember the earliest one we need to wake for.
                  answers.each do |an|
                    if an.refresh
                      unless @queries.detect { |q| q.subscribes_to? an }
                        debug( "no refresh of: a #{an}" )
                        next
                      end
                      if now >= an.refresh
                        an.retries += 1
                        msg.add_question(name, an.data.class)
                      end
                      # TODO: cacher_loop exited with comparison of Bignum with nil failed, v2mdns.rb:478:in `<'
                      begin
                      if !wakefor || an.refresh < wakefor.refresh
                        wakefor = an
                      end
                      rescue
                        error( "an #{an.inspect}" )
                        error( "wakefor #{wakefor.inspect}" )
                        raise
                      end
                    end
                  end
                end
              end

              @cache.asked.each do |name,rtypes|
                # Delete questions no query subscribes to, and that don't need refreshing.
                rtypes.delete_if do |rtype, qu|
                  if !qu.refresh || !@queries.detect { |q| q.subscribes_to? qu }
                    debug( "no refresh of: q #{qu}" )
                    true
                  end
                end
                # Requery questions that need refreshing.
                # Remember the earliest one we need to wake for.
                rtypes.each do |rtype, qu|
                  if now >= qu.refresh
                    msg.add_question(name, rtype)
                  end
                  if !wakefor || qu.refresh < wakefor.refresh
                    wakefor = qu
                  end
                end
              end

              msg.question.uniq!

              msg.each_question { |n,r| debug( "-> q #{n} #{DNS.rrname(r)}" ) }

              send(msg) if msg.question.first

              @waketime = wakefor.refresh if wakefor

              if @waketime
                delay = @waketime - Time.now.to_i
                delay = 1 if delay < 1

                debug( "refresh in #{delay} sec for #{wakefor}" )
              else
                delay = 0
              end

              debug( "sweep end" )
            end
          end # end loop
        end

        def send(msg)
          if( msg.is_a?(Message) )
            msg = msg.encode
          else
            msg = msg.to_str
          end

          # TODO - ensure this doesn't cause DNS lookup for a dotted IP
          begin
            @sock.send(msg, 0, Addr, Port)
          rescue
            error( "send msg failed: #{$!}" )
            raise
          end
        end

        def query_start(query, qu)
          @mutex.synchronize do
            begin
              debug( "start query #{query} with qu #{qu.inspect}" )

              @queries << query

              qu = @cache.add_question(qu)

              wake_cacher_for(qu)

              answers = @cache.answers_for(query.name, query.type)

              query.push( *answers )
             
              # If it wasn't added, then we already are asking the question,
              # don't ask it again.
              if qu
                qmsg = Message.new(0)
                qmsg.rd = 0
                qmsg.add_question(qu.name, qu.type)
                
                send(qmsg)
              end
            rescue
              warn( "fail query #{query} - #{$!}" )
              @queries.delete(query)
              raise
            end
          end
        end

        def query_stop(query)
          @mutex.synchronize do
            debug( "query #{query} - stop" )
            @queries.delete(query)
          end
        end

        def service_start(service, announce_answers = [])
          @mutex.synchronize do
            begin
              @services << service

              debug( "start service #{service.to_s}" )

              if announce_answers.first
                smsg = Message.new(0)
                smsg.rd = 0
                announce_answers.each do |a|
                  smsg.add_answer(*a)
                end
                send(smsg)
              end

            rescue
              warn( "fail service #{service} - #{$!}" )
              @queries.delete(service)
              raise
            end
          end
        end

        def service_stop(service)
          @mutex.synchronize do
            debug( "service #{service} - stop" )
            @services.delete(service)
          end
        end

      end # Responder

      # An mDNS query.
      class Query
        include Net::DNS

        def subscribes_to?(an) # :nodoc:
          if( name.to_s == '*' || name == an.name )
            if( type == IN::ANY || type == an.type )
              return true
            end
          end
          false
        end

        def push(*args) # :nodoc:
          args.each do |an|
            @queue.push(an)
          end
          self
        end

        # The query +name+ from Query.new.
        attr_reader :name
        # The query +type+ from Query.new.
        attr_reader :type

        # Block waiting for a Answer.
        def pop
          @queue.pop
        end


        # Loop forever, yielding each answer.
        def each # :yield: an
          loop do
            yield pop
          end
        end

        # Number of waiting answers.
        def length
          @queue.length
        end

        # A string describing this query.
        def to_s
          "q?#{name}/#{DNS.rrname(type)}"
        end

        # Query for resource records of +type+ for the +name+. +type+ is one of
        # the constants in Net::DNS::IN, such as A or ANY. +name+ is a DNS
        # Name or String, see Name.create. 
        #
        # +name+ can also be the wildcard "*". This will cause no queries to
        # be multicast, but will return every answer seen by the responder.
        def initialize(name, type = IN::ANY)
          @name = Name.create(name)
          @type = type
          @queue = Queue.new

          qu = @name != "*" ? Question.new(@name, @type) : nil

          Responder.instance.query_start(self, qu)
        end

        def stop
          Responder.instance.query_stop(self)
          self
        end
      end # Query

      class BackgroundQuery < Query
        def initialize(name, type = IN::ANY, &proc)
          super(name, type)

          @thread = Thread.new do
            begin
              loop do
                answers = self.pop

                proc.call(self, answers)
              end
            rescue
              # This is noisy, but better than silent failure. If you don't want
              # me to print your exceptions, make sure they don't get out of your
              # Proc!
              $stderr.puts "query #{self} yield raised #{$!}"
            ensure
              Responder.instance.query_stop(self)
            end
          end
        end

        def stop
          @thread.kill
          self
        end
      end # BackgroundQuery

      class Service
        include Net::DNS

        # Questions we can answer:
        #   name.type.domain -> SRV, TXT
        #   type.domain -> PTR:name.type.domain
        #   _services._dns-sd._udp.<domain> -> PTR:type.domain
        def answer_question(name, rtype, amsg)
          case name
          when @instance
            case rtype.object_id
            when IN::ANY.object_id
              amsg.add_answer(@instance, @ttl, @rrsrv)
              amsg.add_answer(@instance, @ttl, @rrtxt)

            when IN::SRV.object_id
              amsg.add_answer(@instance, @ttl, @rrsrv)

            when IN::TXT.object_id
              amsg.add_answer(@instance, @ttl, @rrtxt)
            end

          when @type
            case rtype.object_id
            when IN::ANY.object_id, IN::PTR.object_id
              amsg.add_answer(@type, @ttl, @rrptr)
            end

          when @enum
            case rtype.object_id
            when IN::ANY.object_id, IN::PTR.object_id
              amsg.add_answer(@type, @ttl, @rrenum)
            end

          end
        end

        # Default - 7 days
        def ttl=(secs)
          @ttl = secs.to_int
        end
        # Default - 0
        def priority=(secs)
          @priority = secs.to_int
        end
        # Default - 0
        def weight=(secs)
          @weight = secs.to_int
        end
        # Default - .local
        def domain=(domain)
          @domain = DNS::Name.create(domain.to_str)
        end
        # Set key/value pairs in a TXT record associated with SRV.
        def []=(key, value)
          @txt[key.to_str] = value.to_str
        end

        def to_s
          "MDNS::Service: #{@instance} is #{@target}:#{@port}>"
        end

        def inspect
          "#<#{self.class}: #{@instance} is #{@target}:#{@port}>"
        end

        def initialize(name, type, port, txt = {}, target = Socket.gethostname, &proc)
          # TODO - escape special characters
          @name = DNS::Name.create(name.to_str)
          @type = DNS::Name.create(type.to_str)
          @domain = DNS::Name.create('local')
          @port = port.to_int
          @target = target.to_str

          @txt = txt || {}
          @ttl = 7200 # Arbitrary, but Apple seems to use this value.
          @priority = 0
          @weight = 0

          proc.call(self) if proc

          @domain = Name.new(@domain.to_a, true)
          @type = @type + @domain
          @instance = @name + @type
          @enum = Name.create('_services._dns-sd._udp.') + @domain

          # build the RRs

          @rrenum = IN::PTR.new(@type)

          @rrptr = IN::PTR.new(@instance)

          @rrsrv = IN::SRV.new(@priority, @weight, @port, @target)

          strings = @txt.map { |k,v| k + '=' + v }

          @rrtxt = IN::TXT.new(*strings)

          # class << self
          #   undef_method 'ttl='
          # end
          #  -or-
          # undef :ttl=
          #
          # TODO - all the others

          start
        end

        def start
          Responder.instance.service_start(self, [ [@type, @ttl, @rrptr] ])
          self
        end

        def stop
          Responder.instance.service_stop(self)
          self
        end

      end
    end

  end
end

if $0 == __FILE__

include Net::DNS

$stdout.sync = true
$stderr.sync = true

log = Logger.new(STDERR)
log.level = Logger::DEBUG

MDNS::Responder.instance.log = log

require 'pp'

# I don't want lines of this report intertwingled.
$print_mutex = Mutex.new

def print_answers(q,answers)
  $print_mutex.synchronize do
    puts "query #{q.name}/#{q.type} got #{answers.length} answers:"
    answers.each do |a|
      case a.data
      when IN::A
        puts "  #{a.name} -> A   #{a.data.address.to_s}"
      when Net::DNS::IN::PTR
        puts "  #{a.name} -> PTR #{a.data.name}"
      when Net::DNS::IN::SRV
        puts "  #{a.name} -> SRV #{a.data.target}:#{a.data.port}"
      when Net::DNS::IN::TXT
        puts "  #{a.name} -> TXT"
        a.data.strings.each { |s| puts "    #{s}" }
      else
        puts "  #{a.name} -> ??? #{a.data.inspect}"
      end
    end
  end
end

questions = [
  [ IN::ANY, '*'],
# [ IN::PTR, '_http._tcp.local.' ],
# [ IN::SRV, 'Sam Roberts._http._tcp.local.' ],
# [ IN::ANY, '_ftp._tcp.local.' ],
# [ IN::ANY, '_daap._tcp.local.' ],
# [ IN::A,   'ensemble.local.' ],
# [ IN::ANY, 'ensemble.local.' ],
# [ IN::PTR, '_services._dns-sd.udp.local.' ],
  nil
]

questions.each do |question|
  next unless question

  type, name = question
  MDNS::BackgroundQuery.new(name, type) do |q, an|
    #print_answers(q, [an])
     $print_mutex.synchronize do
       puts "#{q}->#{an}"
     end
  end
end

=begin
q = MDNS::Query.new('ensemble.local.', IN::ANY)
print_answers( q, q.pop )
q.stop

svc = MDNS::Service.new('julie', '_example._tcp', 0xdead) do |s|
  s.ttl = 10
end
=end

Signal.trap('USR1') do
  PP.pp( MDNS::Responder.instance.cache, $stderr )
end

sleep

end

