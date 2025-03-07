local _M = {}


local semaphore = require("ngx.semaphore")
local ws_client = require("resty.websocket.client")
local ws_server = require("resty.websocket.server")
local ssl = require("ngx.ssl")
local ocsp = require("ngx.ocsp")
local http = require("resty.http")
local cjson = require("cjson.safe")
local declarative = require("kong.db.declarative")
local utils = require("kong.tools.utils")
local openssl_x509 = require("resty.openssl.x509")
local system_constants = require("lua_system_constants")
local ffi = require("ffi")
local pl_tablex = require("pl.tablex")
local kong_constants = require("kong.constants")
local string = string
local assert = assert
local setmetatable = setmetatable
local type = type
local math = math
local pcall = pcall
local pairs = pairs
local ngx = ngx
local ngx_log = ngx.log
local ngx_sleep = ngx.sleep
local cjson_decode = cjson.decode
local cjson_encode = cjson.encode
local kong = kong
local ngx_exit = ngx.exit
local exiting = ngx.worker.exiting
local ngx_time = ngx.time
local ngx_var = ngx.var
local io_open = io.open
local table_insert = table.insert
local table_remove = table.remove
local inflate_gzip = utils.inflate_gzip
local deflate_gzip = utils.deflate_gzip


local KONG_VERSION = kong.version
local MAX_PAYLOAD = 4 * 1024 * 1024 -- 4MB
local PING_INTERVAL = 30 -- 30 seconds
local PING_WAIT = PING_INTERVAL * 1.5
local OCSP_TIMEOUT = 5000
local WS_OPTS = {
  timeout = 5000,
  max_payload_len = MAX_PAYLOAD,
}
local ngx_OK = ngx.OK
local ngx_ERR = ngx.ERR
local ngx_WARN = ngx.WARN
local ngx_DEBUG = ngx.DEBUG
local ngx_INFO = ngx.INFO
local ngx_NOTICE = ngx.NOTICE
local WEAK_KEY_MT = { __mode = "k", }
local CERT_DIGEST
local CERT, CERT_KEY
local PLUGINS_LIST
local clients = setmetatable({}, WEAK_KEY_MT)
local prefix = ngx.config.prefix()
local CONFIG_CACHE = prefix .. "/config.cache.json.gz"
local CLUSTERING_SYNC_STATUS = kong_constants.CLUSTERING_SYNC_STATUS
local declarative_config
local next_config


local function update_config(config_table, update_cache)
  assert(type(config_table) == "table")

  if not declarative_config then
    declarative_config = declarative.new_config(kong.configuration)
  end

  local entities, err, _, meta, new_hash = declarative_config:parse_table(config_table)
  if not entities then
    return nil, "bad config received from control plane " .. err
  end

  if declarative.get_current_hash() == new_hash then
    ngx_log(ngx_DEBUG, "same config received from control plane,",
            "no need to reload")
    return true
  end

  -- NOTE: no worker mutex needed as this code can only be
  -- executed by worker 0
  local res, err =
    declarative.load_into_cache_with_events(entities, meta, new_hash)
  if not res then
    return nil, err
  end

  if update_cache then
    -- local persistence only after load finishes without error
    local f, err = io_open(CONFIG_CACHE, "w")
    if not f then
      ngx_log(ngx_ERR, "unable to open cache file: ", err)

    else
      res, err = f:write(assert(deflate_gzip(cjson_encode(config_table))))
      if not res then
        ngx_log(ngx_ERR, "unable to write cache file: ", err)
      end

      f:close()
    end
  end

  return true
end


local function is_timeout(err)
  return err and string.sub(err, -7) == "timeout"
end


local function send_ping(c)
  local hash = declarative.get_current_hash()

  if hash == true then
    hash = string.rep("0", 32)
  end

  local _, err = c:send_ping(hash)
  if err then
    ngx_log(is_timeout(err) and ngx_NOTICE or ngx_WARN, "unable to ping control plane node: ", err)

  else
    ngx_log(ngx_DEBUG, "sent PING packet to control plane")
  end
end


local function communicate(premature, conf)
  if premature then
    -- worker wants to exit
    return
  end

  -- TODO: pick one random CP
  local address = conf.cluster_control_plane

  local c = assert(ws_client:new(WS_OPTS))
  local uri = "wss://" .. address .. "/v1/outlet?node_id=" ..
              kong.node.get_id() ..
              "&node_hostname=" .. kong.node.get_hostname() ..
              "&node_version=" .. KONG_VERSION

  local opts = {
    ssl_verify = true,
    client_cert = CERT,
    client_priv_key = CERT_KEY,
  }
  if conf.cluster_mtls == "shared" then
    opts.server_name = "kong_clustering"
  else
    -- server_name will be set to the host if it is not explicitly defined here
    if conf.cluster_server_name ~= "" then
      opts.server_name = conf.cluster_server_name
    end
  end

  local reconnection_delay = math.random(5, 10)
  local res, err = c:connect(uri, opts)
  if not res then
    ngx_log(ngx_ERR, "connection to control plane ", uri, " broken: ", err,
                     " (retrying after ", reconnection_delay, " seconds)")

    assert(ngx.timer.at(reconnection_delay, communicate, conf))
    return
  end

  -- connection established
  -- first, send out the plugin list to CP so it can make decision on whether
  -- sync will be allowed later
  local _
  _, err = c:send_binary(cjson_encode({ type = "basic_info",
                                        plugins = PLUGINS_LIST, }))
  if err then
    ngx_log(ngx_ERR, "unable to send basic information to control plane: ", uri,
                     " err: ", err,
                     " (retrying after ", reconnection_delay, " seconds)")

    c:close()
    assert(ngx.timer.at(reconnection_delay, communicate, conf))
    return
  end

  local config_semaphore = semaphore.new(0)

  -- how DP connection management works:
  -- three threads are spawned, when any of these threads exits,
  -- it means a fatal error has occurred on the connection,
  -- and the other threads are also killed
  --
  -- * config_thread: it grabs a received declarative config and apply it
  --                  locally. In addition, this thread also persists the
  --                  config onto the local file system
  -- * read_thread: it is the only thread that sends WS frames to the CP
  --                by sending out periodic PING frames to CP that checks
  --                for the healthiness of the WS connection. In addition,
  --                PING messages also contains the current config hash
  --                applied on the local Kong DP
  -- * write_thread: it is the only thread that receives WS frames from the CP,
  --                 and is also responsible for handling timeout detection

  local config_thread = ngx.thread.spawn(function()
    while not exiting() do
      local ok, err = config_semaphore:wait(1)
      if ok then
        local config_table = next_config
        if config_table then
          local pok, res
          pok, res, err = pcall(update_config, config_table, true)
          if pok then
            if not res then
              ngx_log(ngx_ERR, "unable to update running config: ", err)
            end

          else
            ngx_log(ngx_ERR, "unable to update running config: ", res)
          end

          if next_config == config_table then
            next_config = nil
          end
        end

      elseif err ~= "timeout" then
        ngx_log(ngx_ERR, "semaphore wait error: ", err)
      end
    end
  end)

  local write_thread = ngx.thread.spawn(function()
    while not exiting() do
      send_ping(c)

      for _ = 1, PING_INTERVAL do
        ngx_sleep(1)
        if exiting() then
          return
        end
      end
    end
  end)

  local read_thread = ngx.thread.spawn(function()
    local last_seen = ngx_time()
    while not exiting() do
      local data, typ, err = c:recv_frame()
      if err then
        if not is_timeout(err) then
          return nil, "error while receiving frame from control plane: " .. err
        end

        local waited = ngx_time() - last_seen
        if waited > PING_WAIT then
          return nil, "did not receive pong frame from control plane within " .. PING_WAIT .. " seconds"
        end

      else
        if typ == "close" then
          return
        end

        last_seen = ngx_time()

        if typ == "binary" then
          data = assert(inflate_gzip(data))

          local msg = assert(cjson_decode(data))

          if msg.type == "reconfigure" then
            next_config = assert(msg.config_table)

            if config_semaphore:count() <= 0 then
              -- the following line always executes immediately after the `if` check
              -- because `:count` will never yield, end result is that the semaphore
              -- count is guaranteed to not exceed 1
              config_semaphore:post()
            end

            send_ping(c)
          end

        elseif typ == "pong" then
          ngx_log(ngx_DEBUG, "received PONG frame from control plane")
        end
      end
    end
  end)

  local ok, err, perr = ngx.thread.wait(read_thread, write_thread, config_thread)

  ngx.thread.kill(read_thread)
  ngx.thread.kill(write_thread)
  ngx.thread.kill(config_thread)

  c:close()

  if not ok then
    ngx_log(ngx_ERR, err)

  elseif perr then
    ngx_log(ngx_ERR, perr)
  end

  if not exiting() then
    assert(ngx.timer.at(reconnection_delay, communicate, conf))
  end
end


local function validate_shared_cert()
  local cert = ngx_var.ssl_client_raw_cert

  if not cert then
    ngx_log(ngx_ERR, "Data Plane failed to present client certificate " ..
                     "during handshake")
    return ngx_exit(444)
  end

  cert = assert(openssl_x509.new(cert, "PEM"))
  local digest = assert(cert:digest("sha256"))

  if digest ~= CERT_DIGEST then
    ngx_log(ngx_ERR, "Data Plane presented incorrect client certificate " ..
                     "during handshake, expected digest: " .. CERT_DIGEST ..
                     " got: " .. digest)
    return ngx_exit(444)
  end
end


local check_for_revocation_status
do
  local get_full_client_certificate_chain = require("resty.kong.tls").get_full_client_certificate_chain
  check_for_revocation_status = function ()
    local cert, err = get_full_client_certificate_chain()
    if not cert then
      return nil, err
    end

    local der_cert
    der_cert, err = ssl.cert_pem_to_der(cert)
    if not der_cert then
      return nil, "failed to convert certificate chain from PEM to DER: " .. err
    end

    local ocsp_url
    ocsp_url, err = ocsp.get_ocsp_responder_from_der_chain(der_cert)
    if not ocsp_url then
      return nil, err or "OCSP responder endpoint can not be determined, " ..
                         "maybe the client certificate is missing the " ..
                         "required extensions"
    end

    local ocsp_req
    ocsp_req, err = ocsp.create_ocsp_request(der_cert)
    if not ocsp_req then
      return nil, "failed to create OCSP request: " .. err
    end

    local c = http.new()
    local res
    res, err = c:request_uri(ocsp_url, {
      headers = {
        ["Content-Type"] = "application/ocsp-request"
      },
      timeout = OCSP_TIMEOUT,
      method = "POST",
      body = ocsp_req,
    })

    if not res then
      return nil, "failed sending request to OCSP responder: " .. tostring(err)
    end
    if res.status ~= 200 then
      return nil, "OCSP responder returns bad HTTP status code: " .. res.status
    end

    local ocsp_resp = res.body
    if not ocsp_resp or #ocsp_resp == 0 then
      return nil, "unexpected response from OCSP responder: empty body"
    end

    res, err = ocsp.validate_ocsp_response(ocsp_resp, der_cert)
    if not res then
      return false, "failed to validate OCSP response: " .. err
    end

    return true
  end
end


local MAJOR_MINOR_PATTERN = "^(%d+)%.(%d+)%.%d+"

local function should_send_config_update(node_version, node_plugins)
  if not node_version or not node_plugins then
    return false, "your DP did not provide version information to the CP, " ..
                  "Kong CP after 2.3 requires such information in order to " ..
                  "ensure generated config is compatible with DPs. " ..
                  "Sync is suspended for this DP and will resume " ..
                  "automatically once this DP also upgrades to 2.3 or later"
  end

  local major_cp, minor_cp = KONG_VERSION:match(MAJOR_MINOR_PATTERN)
  local major_node, minor_node = node_version:match(MAJOR_MINOR_PATTERN)
  minor_cp = tonumber(minor_cp)
  minor_node = tonumber(minor_node)

  if major_cp ~= major_node or minor_cp - 2 > minor_node or minor_cp < minor_node then
    return false, "version incompatible, CP version: " .. KONG_VERSION ..
                  " DP version: " .. node_version ..
                  " DP versions acceptable are " ..
                  major_cp .. "." .. math.max(0, minor_cp - 2) .. " to " ..
                  major_cp .. "." .. minor_cp .. "(edges included)",
                  CLUSTERING_SYNC_STATUS.KONG_VERSION_INCOMPATIBLE
  end

  -- allow DP to have a superset of CP's plugins
  local p, np
  local i, j = #PLUGINS_LIST, #node_plugins

  if j < i then
    return false, "CP and DP does not have same set of plugins installed",
                  CLUSTERING_SYNC_STATUS.PLUGIN_SET_INCOMPATIBLE
  end

  while i > 0 and j > 0 do
    p = PLUGINS_LIST[i]
    np = node_plugins[j]

    if p.name ~= np.name then
      goto continue
    end

    -- ignore plugins without a version (route-by-header is deprecated)
    if p.version and np.version then
      -- major/minor check that ignores anything after the second digit
      local major_minor_p = p.version:match("^(%d+%.%d+)") or "not_a_version"
      local major_minor_np = np.version:match("^(%d+%.%d+)") or "still_not_a_version"

      if major_minor_p ~= major_minor_np then
        return false, "plugin \"" .. p.name .. "\" version incompatible, " ..
                      "CP version: " .. tostring(p.version) ..
                      " DP version: " .. tostring(np.version) ..
                      " DP plugin version acceptable is "..
                      major_minor_p .. ".x",
                      CLUSTERING_SYNC_STATUS.PLUGIN_VERSION_INCOMPATIBLE
      end
    end

    i = i - 1
    ::continue::
    j = j - 1
  end

  if i > 0 then
    return false, "CP and DP does not have same set of plugins installed",
                  CLUSTERING_SYNC_STATUS.PLUGIN_SET_INCOMPATIBLE
  end

  return true
end


function _M.handle_cp_websocket()
  -- use mutual TLS authentication
  if kong.configuration.cluster_mtls == "shared" then
    validate_shared_cert()

  elseif kong.configuration.cluster_ocsp ~= "off" then
    local res, err = check_for_revocation_status()
    if res == false then
      ngx_log(ngx_ERR, "DP client certificate was revoked: ", err)
      return ngx_exit(444)

    elseif not res then
      ngx_log(ngx_WARN, "DP client certificate revocation check failed: ", err)
      if kong.configuration.cluster_ocsp == "on" then
        return ngx_exit(444)
      end
    end
  end

  local node_id = ngx_var.arg_node_id
  if not node_id then
    ngx_exit(400)
  end

  local node_hostname = ngx_var.arg_node_hostname
  local node_ip = ngx_var.remote_addr
  local node_version = ngx_var.arg_node_version
  local node_plugins

  local wb, err = ws_server:new(WS_OPTS)
  if not wb then
    ngx_log(ngx_ERR, "failed to perform server side WebSocket handshake: ", err)
    return ngx_exit(444)
  end

  -- connection established
  -- receive basic_info
  local data, typ
  data, typ, err = wb:recv_frame()
  if err then
    ngx_log(ngx_ERR, "failed to receive WebSocket basic_info frame: ", err)
    wb:close()
    return ngx_exit(444)

  elseif typ == "binary" then
    data = cjson_decode(data)
    assert(data.type =="basic_info")
    node_plugins = assert(data.plugins)
  end

  local queue
  do
    local queue_semaphore = semaphore.new()
    queue = {
      wait = function(...)
        return queue_semaphore:wait(...)
      end,
      post = function(...)
        return queue_semaphore:post(...)
      end
    }
  end

  clients[wb] = queue

  local res, sync_status
  res, err, sync_status = should_send_config_update(node_version, node_plugins)
  if res then
    sync_status = CLUSTERING_SYNC_STATUS.NORMAL
    local config_table
    -- unconditionally send config update to new clients to
    -- ensure they have latest version running
    config_table, err = declarative.export_config()
    if config_table then
      local payload = cjson_encode({ type = "reconfigure",
                                     config_table = config_table,
                                   })
      payload = assert(deflate_gzip(payload))
      table_insert(queue, payload)
      queue.post()

    else
      ngx_log(ngx_ERR, "unable to export config from database: ".. err)
    end

  else
    ngx_log(ngx_WARN, "unable to send updated configuration to " ..
                      "DP node with hostname: " .. node_hostname ..
                      " ip: " .. node_ip ..
                      " reason: " .. err)
  end
  -- how CP connection management works:
  -- two threads are spawned, when any of these threads exits,
  -- it means a fatal error has occurred on the connection,
  -- and the other thread is also killed
  --
  -- * read_thread: it is the only thread that receives WS frames from the DP
  --                and records the current DP status in the database,
  --                and is also responsible for handling timeout detection
  -- * write_thread: it is the only thread that sends WS frames to the DP by
  --                 grabbing any messages currently in the send queue and
  --                 send them to the DP in a FIFO order. Notice that the
  --                 PONG frames are also sent by this thread after they are
  --                 queued by the read_thread

  local read_thread = ngx.thread.spawn(function()
    local last_seen = ngx_time()
    while not exiting() do
      local data, typ, err = wb:recv_frame()

      if exiting() then
        return
      end

      if err then
        if not is_timeout(err) then
          return nil, err
        end

        local waited = ngx_time() - last_seen
        if waited > PING_WAIT then
          return nil, "did not receive ping frame from data plane within " ..
                      PING_WAIT .. " seconds"
        end

      else
        if typ == "close" then
          return
        end

        if not data then
          return nil, "did not receive ping frame from data plane"
        end

        -- dps only send pings
        if typ ~= "ping" then
          return nil, "invalid websocket frame received from a data plane: " .. typ
        end

        -- queue PONG to avoid races
        table_insert(queue, "PONG")
        queue.post()

        last_seen = ngx_time()

        local ok
        ok, err = kong.db.clustering_data_planes:upsert({ id = node_id, }, {
          last_seen = last_seen,
          config_hash = data ~= "" and data or nil,
          hostname = node_hostname,
          ip = node_ip,
          version = node_version,
          sync_status = sync_status,
        }, { ttl = kong.configuration.cluster_data_plane_purge_delay, })
        if not ok then
          ngx_log(ngx_ERR, "unable to update clustering data plane status: ", err)
        end
      end
    end
  end)

  local write_thread = ngx.thread.spawn(function()
    while not exiting() do
      local ok, err = queue.wait(5)
      if exiting() then
        return
      end
      if ok then
        local payload = table_remove(queue, 1)
        if not payload then
          return nil, "config queue can not be empty after semaphore returns"
        end

        if payload == "PONG" then
          local _, err = wb:send_pong()
          if err then
            if not is_timeout(err) then
              return nil, "failed to send PONG back to data plane: " .. err
            end

            ngx_log(ngx_NOTICE, "failed to send PONG back to data plane: ", err)

          else
            ngx_log(ngx_DEBUG, "sent PONG packet to data plane")
          end

        else
          ok, err = should_send_config_update(node_version, node_plugins)
          if ok then
            -- config update
            local _, err = wb:send_binary(payload)
            if err then
              if not is_timeout(err) then
                return nil, "unable to send updated configuration to node: " .. err
              end

              ngx_log(ngx_NOTICE, "unable to send updated configuration to node: ", err)

            else
              ngx_log(ngx_DEBUG, "sent config update to node")
            end

          else
            ngx_log(ngx_WARN, "unable to send updated configuration to " ..
                              "DP node with hostname: " .. node_hostname ..
                              " ip: " .. node_ip ..
                              " reason: " .. err)
          end
        end

      elseif err ~= "timeout" then
        return nil, "semaphore wait error: " .. err
      end
    end
  end)

  local ok, err, perr = ngx.thread.wait(write_thread, read_thread)

  ngx.thread.kill(write_thread)
  ngx.thread.kill(read_thread)

  wb:send_close()

  if not ok then
    ngx_log(ngx_ERR, err)
    return ngx_exit(ngx_ERR)
  end

  if perr then
    ngx_log(ngx_ERR, perr)
    return ngx_exit(ngx_ERR)
  end

  return ngx_exit(ngx_OK)
end


local function push_config(config_table)
  if not config_table then
    local err
    config_table, err = declarative.export_config()
    if not config_table then
      ngx_log(ngx_ERR, "unable to export config from database: " .. err)
      return
    end
  end

  local payload = cjson_encode({ type = "reconfigure",
                                 config_table = config_table,
                               })
  payload = assert(deflate_gzip(payload))

  local n = 0

  for _, queue in pairs(clients) do
    table_insert(queue, payload)
    queue.post()

    n = n + 1
  end

  ngx_log(ngx_DEBUG, "config pushed to ", n, " clients")
end


local function push_config_timer(premature, semaphore, delay)
  if premature then
    return
  end

  while not exiting() do
    local ok, err = semaphore:wait(1)
    if exiting() then
      return
    end
    if ok then
      ok, err = pcall(push_config)
      if ok then
        local sleep_left = delay
        while sleep_left > 0 do
          if sleep_left <= 1 then
            ngx.sleep(sleep_left)
            break
          end

          ngx.sleep(1)

          if exiting() then
            return
          end

          sleep_left = sleep_left - 1
        end

      else
        ngx_log(ngx_ERR, "export and pushing config failed: ", err)
      end

    elseif err ~= "timeout" then
      ngx_log(ngx_ERR, "semaphore wait error: ", err)
    end
  end
end


local function init_mtls(conf)
  local f, err = io_open(conf.cluster_cert, "r")
  if not f then
    return nil, "unable to open cluster cert file: " .. err
  end

  local cert
  cert, err = f:read("*a")
  if not cert then
    f:close()
    return nil, "unable to read cluster cert file: " .. err
  end

  f:close()

  CERT, err = ssl.parse_pem_cert(cert)
  if not CERT then
    return nil, err
  end

  cert = openssl_x509.new(cert, "PEM")

  CERT_DIGEST = cert:digest("sha256")

  f, err = io_open(conf.cluster_cert_key, "r")
  if not f then
    return nil, "unable to open cluster cert key file: " .. err
  end

  local key
  key, err = f:read("*a")
  if not key then
    f:close()
    return nil, "unable to read cluster cert key file: " .. err
  end

  f:close()

  CERT_KEY, err = ssl.parse_pem_priv_key(key)
  if not CERT_KEY then
    return nil, err
  end

  return true
end


function _M.init(conf)
  assert(conf, "conf can not be nil", 2)

  if conf.role ~= "data_plane" and conf.role ~= "control_plane" then
    return
  end

  assert(init_mtls(conf))
end


function _M.init_worker(conf)
  assert(conf, "conf can not be nil", 2)

  if conf.role ~= "data_plane" and conf.role ~= "control_plane" then
    return
  end

  PLUGINS_LIST = assert(kong.db.plugins:get_handlers())
  table.sort(PLUGINS_LIST, function(a, b)
    return a.name:lower() < b.name:lower()
  end)

  PLUGINS_LIST = pl_tablex.map(function(p)
    return { name = p.name, version = p.handler.VERSION, }
  end, PLUGINS_LIST)

  if conf.role == "data_plane" then
    -- ROLE = "data_plane"

    if ngx.worker.id() == 0 then
      local f = io_open(CONFIG_CACHE, "r")
      if f then
        local config, err = f:read("*a")
        if not config then
          ngx_log(ngx_ERR, "unable to read cached config file: ", err)
        end

        f:close()

        if config and #config > 0 then
          ngx_log(ngx_INFO, "found cached copy of data-plane config, loading..")

          local err

          config, err = inflate_gzip(config)
          if config then
            config = cjson_decode(config)

            if config then
              local res
              res, err = update_config(config, false)
              if not res then
                ngx_log(ngx_ERR, "unable to update running config from cache: ", err)
              end
            end

          else
            ngx_log(ngx_ERR, "unable to inflate cached config: ",
                    err, ", ignoring...")
          end
        end

      else
        -- CONFIG_CACHE does not exist, pre create one with 0600 permission
        local fd = ffi.C.open(CONFIG_CACHE, bit.bor(system_constants.O_RDONLY(),
                                                    system_constants.O_CREAT()),
                                            bit.bor(system_constants.S_IRUSR(),
                                                    system_constants.S_IWUSR()))
        if fd == -1 then
          ngx_log(ngx_ERR, "unable to pre-create cached config file: ",
                  ffi.string(ffi.C.strerror(ffi.errno())))

        else
          ffi.C.close(fd)
        end
      end

      assert(ngx.timer.at(0, communicate, conf))
    end

  elseif conf.role == "control_plane" then
    -- ROLE = "control_plane"

    local push_config_semaphore = semaphore.new()

    -- Sends "clustering", "push_config" to all workers in the same node, including self
    local function post_push_config_event_to_node_workers(data)
      if type(data) == "table" and data.schema and
         data.schema.db_export == false
      then
        return
      end

      -- we have to re-broadcast event using `post` because the dao
      -- events were sent using `post_local` which means not all workers
      -- can receive it
      local res, err = kong.worker_events.post("clustering", "push_config")
      if not res then
        ngx_log(ngx_ERR, "unable to broadcast event: " .. err)
      end
    end

    -- The "invalidations" cluster event gets inserted in the cluster when there's a crud change
    -- (like an insertion or deletion). Only one worker per kong node receives this callback.
    -- This makes such node post push_config events to all the cp workers on its node
    kong.cluster_events:subscribe("invalidations", post_push_config_event_to_node_workers)

    -- The "dao:crud" event is triggered using post_local, which eventually generates an
    -- "invalidations" cluster event. It is assumed that the workers in the
    -- same node where the dao:crud event originated will "know" about the update mostly via
    -- changes in the cache shared dict. Since DPs don't use the cache, nodes in the same
    -- kong node where the event originated will need to be notified so they push config to
    -- their DPs
    kong.worker_events.register(post_push_config_event_to_node_workers, "dao:crud")

    -- When "clustering", "push_config" worker event is received by a worker,
    -- it loads and pushes the config to its the connected DPs
    kong.worker_events.register(function(_)
      if push_config_semaphore:count() <= 0 then
        -- the following line always executes immediately after the `if` check
        -- because `:count` will never yield, end result is that the semaphore
        -- count is guaranteed to not exceed 1
        push_config_semaphore:post()
      end
    end, "clustering", "push_config")

    ngx.timer.at(0, push_config_timer, push_config_semaphore, conf.db_update_frequency)
  end
end


return _M
