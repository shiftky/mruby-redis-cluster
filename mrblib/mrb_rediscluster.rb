class RedisCluster

  HASH_SLOTS = 16384
  MAX_REDIRECTIONS = 16
  DEFAULT_MAX_CACHED_CONNECTIONS = 2

  def initialize(startup_nodes, max_cached_connections=nil)
    @startup_nodes = startup_nodes
    @max_cached_connections = max_cached_connections || DEFAULT_MAX_CACHED_CONNECTIONS

    @slots = {}
    @connections = {}
    @refresh_slots_cache = false

    initialize_slots_cache
  end

  def method_missing(*argv)
    send_cluster_command(argv)
  end

  def cluster_slots
    @startup_nodes.each do |n|
      begin
        redis = Redis.new(n[:host], n[:port])
        return redis.cluster('slots')
      rescue
        next
      end
    end
    raise 'Error: failed to get cluster slots'
  end

  def cluster_nodes
    @startup_nodes.each do |n|
      begin
        redis = Redis.new(n[:host], n[:port])
        resp = redis.cluster('nodes')
      rescue
        next
      end

      nodes = []
      resp.split("\n").each do |r|
        id, ip_port, flags = r.split(' ')
        host, port = ip_port.split(':')
        nodes << {
          id: id,
          host: host,
          port: port.to_i,
          name: "#{host}:#{port}",
          flags: flags
        }
      end
      return nodes
    end
    raise 'Error: failed to get cluster nodes'
  end

  def initialize_slots_cache
    @startup_nodes = cluster_nodes
    cluster_slots.each do |r|
      (r[0]..r[1]).each do |slot|
        host, port = r[2]
        node = { host: host, port: port, name: "#{host}:#{port}" }
        @slots[slot] = node
        unless @startup_nodes.include?(node)
          @startup_nodes << node
        end
      end
    end

    @refresh_slots_cache = false
  end

  def send_cluster_command(argv)
    initialize_slots_cache if @refresh_slots_cache

    try_random_connection = false
    asking = false
    num_redirects = 0

    while num_redirects < MAX_REDIRECTIONS
      num_redirects += 1

      key = extract_key(argv)
      slot = hash_slot(key)

      if try_random_connection
        redis = get_random_connection
        try_random_connection = false
      else
        redis = get_connection_by(slot)
      end

      begin
        redis.asking if asking
        asking = false
        return redis.send(argv[0], *argv[1..-1])
      rescue Redis::ConnectionError => e
        try_random_connection = true
      rescue Redis::ReplyError => e
        err, newslot, ip_port = e.message.split
        if err == 'MOVED'
          @refresh_slots_cache = true
          host, port = ip_port.split(':')
          newslot = newslot.to_i
          @slots[newslot] = { host: host, port: port, name: ip_port }
        elsif err == 'ASK'
          asking = true
        else
          raise e
        end
      end
    end
    raise "Error: #{argv[0]} #{argv[1..-1].join(' ')} - max redirection limit exceeded (#{MAX_REDIRECTIONS} times)"
  end

  def get_random_connection
    @startup_nodes.shuffle.each do |node|
      conn = @connections[node[:name]]
      begin
        if conn.nil?
          conn = Redis.new(node[:host], node[:port])
          if conn.ping == 'PONG'
            close_existing_connection
            @connections[node[:name]] = conn
            return conn
          else
            conn.close
          end
        else
          return conn if conn.ping == 'PONG'
        end
      rescue
        next
      end
    end
    raise 'Error: failed to get random connection'
  end

  def get_connection_by(slot)
    node = @slots[slot]
    return get_random_connection if node.nil?

    if ! @connections[node[:name]]
      close_existing_connection
      @connections[node[:name]] = Redis.new(node[:host], node[:port])
    end

    @connections[node[:name]]
  end

  def close_existing_connection
    while @connections.length > DEFAULT_MAX_CACHED_CONNECTIONS
      name, conn = @connections.shift
      conn.close
    end
  end

  def close_all_connections
    @connections.each do |name, conn|
      name, conn = @connections.shift
      conn.close
    end
  end

  def extract_key(argv)
    cmd = argv[0].to_s.downcase
    if %w(info multi exec slaveof config shutdown).include?(cmd)
      return nil
    end
    return argv[1]
  end

  def hash_slot(key)
    s = key.index "{"
    if s
      e = key.index "}",s+1
      if e && e != s+1
        key = key[s+1..e-1]
      end
    end
    RedisClusterCRC16.crc16(key) % HASH_SLOTS
  end
end
