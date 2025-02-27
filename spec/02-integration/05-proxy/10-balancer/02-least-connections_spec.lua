local cjson   = require "cjson"
local helpers = require "spec.helpers"

local function get_available_port()
  local socket = require("socket")
  local server = assert(socket.bind("*", 0))
  local _, port = server:getsockname()
  server:close()
  return port
end


local test_port1 = get_available_port()
local test_port2 = get_available_port()


-- create two servers, one double the delay of the other
local fixtures = {
  http_mock = {
    least_connections = [[

      server {
          server_name mock_delay_100;
          listen ]] .. test_port1 .. [[;

          location ~ "/leastconnections" {
              content_by_lua_block {
                local delay = 100
                ngx.sleep(delay/1000)
                ngx.say(delay)
                ngx.exit(200)
              }
          }
      }

      server {
          server_name mock_delay_200;
          listen ]] .. test_port2 .. [[;

          location ~ "/leastconnections" {
              content_by_lua_block {
                local delay = 200
                ngx.sleep(delay/1000)
                ngx.say(delay)
                ngx.exit(200)
              }
          }
      }

  ]]
  },
}


for _, strategy in helpers.each_strategy() do
  describe("Balancer: least-connections [#" .. strategy .. "]", function()
    local upstream1_id

    lazy_setup(function()
      local bp = helpers.get_db_utils(strategy, {
        "routes",
        "services",
        "upstreams",
        "targets",
      })

      assert(bp.routes:insert({
        hosts      = { "least1.test" },
        protocols  = { "http" },
        service    = bp.services:insert({
          protocol = "http",
          host     = "lcupstream",
        })
      }))

      local upstream1 = assert(bp.upstreams:insert({
        name = "lcupstream",
        algorithm = "least-connections",
      }))
      upstream1_id = upstream1.id

      assert(bp.targets:insert({
        upstream = upstream1,
        target = "127.0.0.1:" .. test_port1,
        weight = 100,
      }))

      assert(bp.targets:insert({
        upstream = upstream1,
        target = "127.0.0.1:" .. test_port2,
        weight = 100,
      }))

      assert(helpers.start_kong({
        database   = strategy,
        nginx_conf = "spec/fixtures/custom_nginx.template",
      }, nil, nil, fixtures))
    end)

    before_each(function()
      -- wait until helper servers are alive
      helpers.wait_until(function()
        local client = helpers.proxy_client()
        local res = assert(client:send({
          method = "GET",
          path = "/leastconnections",
          headers = {
            ["Host"] = "least1.test"
          },
        }))
        client:close()
        return res.status == 200
      end, 20)
    end)

    lazy_teardown(function()
      helpers.stop_kong()
    end)

    it("balances by least-connections", function()
      local thread_max = 50 -- maximum number of threads to use
      local done = false
      local results = {}
      local threads = {}

      local handler = function()
        while not done do
          local client = helpers.proxy_client()
          local res = assert(client:send({
            method = "GET",
            path = "/leastconnections",
            headers = {
              ["Host"] = "least1.test"
            },
          }))
          assert(res.status == 200)
          local body = tonumber(assert(res:read_body()))
          results[body] = (results[body] or 0) + 1
          client:close()
        end
      end

      -- start the threads
      for i = 1, thread_max do
        threads[#threads+1] = ngx.thread.spawn(handler)
      end

      -- wait while we're executing
      local finish_at = ngx.now() + 1.5
      repeat
        ngx.sleep(0.1)
      until ngx.now() >= finish_at

      -- finish up
      done = true
      for i = 1, thread_max do
        ngx.thread.wait(threads[i])
      end

      --assert.equal(results,false)
      local ratio = results[100]/results[200]
      assert.near(2, ratio, 0.8)
    end)

    if strategy ~= "off" then
      it("add and remove targets", function()
        local api_client = helpers.admin_client()

        -- create a new target
        local res = assert(api_client:send({
          method = "POST",
          path = "/upstreams/" .. upstream1_id .. "/targets",
          headers = {
            ["Content-Type"] = "application/json",
          },
          body = {
            target = "127.0.0.1:10003",
            weight = 100
          },
        }))
        api_client:close()
        assert.same(201, res.status)

        -- check if it is available
        api_client = helpers.admin_client()
        local res, err = api_client:send({
          method = "GET",
          path = "/upstreams/" .. upstream1_id .. "/targets/all",
        })
        assert.is_nil(err)

        local body = cjson.decode((res:read_body()))
        api_client:close()
        local found = false
        for _, entry in ipairs(body.data) do
          if entry.target == "127.0.0.1:10003" and entry.weight == 100 then
            found = true
            break
          end
        end
        assert.is_true(found)

        -- update the target and assert that it still exists with weight == 0
        api_client = helpers.admin_client()
        res, err = api_client:send({
          method = "PATCH",
          path = "/upstreams/" .. upstream1_id .. "/targets/127.0.0.1:10003",
          headers = {
            ["Content-Type"] = "application/json",
          },
          body = {
            weight = 0
          },
        })
        assert.is_nil(err)
        assert.same(200, res.status)
        local json = assert.response(res).has.jsonbody()
        assert.is_string(json.id)
        assert.are.equal("127.0.0.1:10003", json.target)
        assert.are.equal(0, json.weight)
        api_client:close()

        api_client = helpers.admin_client()
        local res, err = api_client:send({
          method = "GET",
          path = "/upstreams/" .. upstream1_id .. "/targets/all",
        })
        assert.is_nil(err)

        local body = cjson.decode((res:read_body()))
        api_client:close()
        local found = false
        for _, entry in ipairs(body.data) do
          if entry.target == "127.0.0.1:10003" and entry.weight == 0 then
            found = true
            break
          end
        end
        assert.is_true(found)
      end)
    end
  end)

  if strategy ~= "off" then
    describe("Balancer: add and remove a single target to a least-connection upstream [#" .. strategy .. "]", function()
      local bp

      lazy_setup(function()
        bp = helpers.get_db_utils(strategy, {
          "routes",
          "services",
          "upstreams",
          "targets",
        })

        assert(helpers.start_kong({
          database   = strategy,
          nginx_conf = "spec/fixtures/custom_nginx.template",
        }, nil, nil, fixtures))
      end)

      lazy_teardown(function()
        helpers.stop_kong()
      end)

      it("add and remove targets", function()
        local an_upstream = assert(bp.upstreams:insert({
          name = "anupstream",
          algorithm = "least-connections",
        }))

        local api_client = helpers.admin_client()

        -- create a new target
        local res = assert(api_client:send({
          method = "POST",
          path = "/upstreams/" .. an_upstream.id .. "/targets",
          headers = {
            ["Content-Type"] = "application/json",
          },
          body = {
            target = "127.0.0.1:" .. test_port1,
            weight = 100
          },
        }))
        api_client:close()
        assert.same(201, res.status)

        -- check if it is available
        api_client = helpers.admin_client()
        local res, err = api_client:send({
          method = "GET",
          path = "/upstreams/" .. an_upstream.id .. "/targets/all",
        })
        assert.is_nil(err)

        local body = cjson.decode((res:read_body()))
        api_client:close()
        local found = false
        for _, entry in ipairs(body.data) do
          if entry.target == "127.0.0.1:" .. test_port1 and entry.weight == 100 then
            found = true
            break
          end
        end
        assert.is_true(found)

        -- delete the target and assert that it is gone
        api_client = helpers.admin_client()
        res, err = api_client:send({
          method = "DELETE",
          path = "/upstreams/" .. an_upstream.id .. "/targets/127.0.0.1:" .. test_port1,
        })
        assert.is_nil(err)
        assert.same(204, res.status)
        api_client:close()

        api_client = helpers.admin_client()
        local res, err = api_client:send({
          method = "GET",
          path = "/upstreams/" .. an_upstream.id .. "/targets/all",
        })
        assert.is_nil(err)

        local body = cjson.decode((res:read_body()))
        api_client:close()
        local found = false
        for _, entry in ipairs(body.data) do
          if entry.target == "127.0.0.1:" .. test_port1 and entry.weight == 0 then
            found = true
            break
          end
        end
        assert.is_false(found)
      end)
    end)
  end
end
