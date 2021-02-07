--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--

local core = require("apisix.core")
local json = require("apisix.core.json")
local http = require("resty.http")
local ck = require("resty.cookie")
local ngx = ngx
local rawget = rawget
local rawset = rawset
local setmetatable = setmetatable
local string = string

local plugin_name = "auth-hook"
local hook_lrucache = core.lrucache.new({
    ttl = 60, count = 1024
})

local schema = {
    type = "object",
    properties = {
        auth_hook_id = { type = "string", minLength = 1, maxLength = 100, default = "unset" },
        auth_hook_uri = { type = "string", minLength = 1, maxLength = 4096 },
        auth_hook_method = {
            type = "string",
            default = "GET",
            enum = { "GET", "POST" },
        },
        hook_headers = {
            type = "array",
            items = {
                type = "string",
                minLength = 1, maxLength = 100
            },
            uniqueItems = true
        },
        hook_args = {
            type = "array",
            items = {
                type = "string",
                minLength = 1, maxLength = 100
            },
            uniqueItems = true
        },
        hook_res_to_headers = {
            type = "array",
            items = {
                type = "string",
                minLength = 1, maxLength = 100
            },
            uniqueItems = true
        },
        hook_keepalive = { type = "boolean", default = true },
        hook_keepalive_timeout = { type = "integer", minimum = 1000, default = 60000 },
        hook_keepalive_pool = { type = "integer", minimum = 1, default = 5 },
        hook_res_to_header_prefix = { type = "string", default = "X-", minLength = 1, maxLength = 100 },
        hook_cache = { type = "boolean", default = false },
        check_termination = { type = "boolean", default = true },
    },
    required = { "auth_hook_uri"},
}

local _M = {
    version = 0.1,
    priority = 1000,
    name = plugin_name,
    schema = schema,
}

function _M.check_schema(conf)
    local ok, err = core.schema.check(schema, conf)
    if not ok then
        return false, err
    end

    return true
end

local function get_auth_token(ctx)
    local token = ctx.var.http_x_auth_token
    if token then
        return token
    end

    token = ctx.var.http_authorization
    if token then
        return token
    end

    token = ctx.var.arg_auth_token
    if token then
        return token
    end

    local cookie, err = ck:new()
    if not cookie then
        return nil, err
    end

    local val, error = cookie:get("auth-token")
    return val, error
end

local function fail_response(message, init_values)
    local response = init_values or {}
    response.message = message
    return response
end

--初始化headers
local function new_table()
    local t = {}
    local lt = {}
    local _mt = {
        __index = function(t, k)
            return rawget(lt, string.lower(k))
        end,
        __newindex = function(t, k, v)
            rawset(t, k, v)
            rawset(lt, string.lower(k), v)
        end,
    }
    return setmetatable(t, _mt)
end


--获取需要传输的headers
local function request_headers(config, ctx)
    local req_headers = new_table();
    local headers = core.request.headers(ctx);
    local hook_headers = config.hook_headers
    if not hook_headers then
        return req_headers
    end
    for field in pairs(hook_headers) do
        local v = headers[field]
        if v then
            req_headers[field] = v
        end
    end
    return req_headers;
end


--获取需要传输的headers
local function res_init_headers(config)

    local prefix = config.hook_res_to_header_prefix or ''
    local hook_res_to_headers = config.hook_res_to_headers;

    if type(hook_res_to_headers) ~= "table" then
        return
    end
    core.request.set_header(prefix .. "auth-data", nil)
    for field, val in pairs(hook_res_to_headers) do
        local f = string.gsub(val, '_', '-')
        core.request.set_header(prefix .. f, nil)
        core.response.set_header(prefix .. f, nil)

    end
    return ;
end

--获取需要传输的headers
local function res_to_headers(config, data)

    local prefix = config.hook_res_to_header_prefix or ''
    local hook_res_to_headers = config.hook_res_to_headers;
    if type(hook_res_to_headers) ~= "table" or type(data) ~= "table" then
        return
    end
    core.request.set_header(prefix .. "auth-data", core.json.encode(data))
    core.response.set_header(prefix .. "auth-data", core.json.encode(data))
    for field, val in pairs(hook_res_to_headers) do
        local v = data[val]
        core.log.warn(v, '---', field, '-----', val)
        if v then
            core.log.warn(v)
            if type(v) == "table" then
                v = core.json.encode(v)
            end
            local f = string.gsub(val, '_', '-')
            core.request.set_header(prefix .. f, v)
            core.response.set_header(prefix .. f, v)

        end
    end
    return ;
end


--获取需要传输的args
local function get_hook_args(hook_args)

    local req_args = new_table();
    if not hook_args then
        return req_args
    end
    local args = ngx.req.get_uri_args()
    for field in pairs(hook_args) do
        local v = args[field]
        if v then
            req_args[field] = v
        end
    end
    return req_args;
end

-- Configure request parameters.
local function hook_configure_params(args, config, myheaders)
    -- TLS verification.
    myheaders["Content-Type"] = "application/json; charset=utf-8"
    local auth_hook_params = {
        ssl_verify = false,
        method = config.auth_hook_method,
        headers = myheaders,
    };
    local url = config.auth_hook_uri;
    -- Keepalive options.
    if config.hook_keepalive then
        auth_hook_params.keepalive_timeout = config.hook_keepalive_timeout
        auth_hook_params.keepalive_pool = config.hook_keepalive_pool
    else
        auth_hook_params.keepalive = config.hook_keepalive
    end
    url = config.auth_hook_uri .. "?" .. ngx.encode_args(args)
    if config.auth_hook_method == 'POST' then
        auth_hook_params.body = nil
    else
        auth_hook_params.body = nil
    end
    return auth_hook_params, url
end

-- timeout in ms
local function http_req(url, auth_hook_params)

    local httpc = http.new()
    httpc:set_timeout(1000 * 10)
    core.log.warn("input conf: ", core.json.encode(auth_hook_params))
    local res, err = httpc:request_uri(url, auth_hook_params)
    if err then
        core.log.error("FAIL REQUEST [ ", core.json.encode(auth_hook_params), " ] failed! res is nil, err:", err)
        return nil, err
    end

    return res
end

local function get_auth_info(config, ctx, action, path, client_ip, auth_token)
    local errmsg
    local myheaders = request_headers(config, ctx)
    myheaders["X-Client-Ip"] = client_ip
    myheaders["Authorization"] = auth_token
    myheaders["Auth-Hook-Id"] = config.auth_hook_id
    local args = get_hook_args(config.hook_args)
    args['hook_path'] = path
    args['hook_action'] = action
    args['hook_client_ip'] = client_ip
    core.response.set_header("hook-cache", 'no-cache')
    local auth_hook_params, url = hook_configure_params(args, config, myheaders)
    local res, err = http_req(url, auth_hook_params)
    if err then
        core.log.error("fail request: ", url, ", err:", err)
        return {
            status = 500,
            err = "request to hook-server failed, err:" .. err
        }
    end

    if res.status ~= 200 and res.status ~= 401 then
        return {
            status = 500,
            err = 'request to hook-server failed, status:' .. res.status
        }
    end

    local res_body, res_err = json.decode(res.body)
    if res_err then
        errmsg = 'check permission failed! parse response json failed!'
        core.log.error("json.decode(", res.body, ") failed! err:", res_err)
        return { status = res.status, err = errmsg }
    else
        errmsg = res_body.message
        return { status = res.status, err = errmsg, body = res_body }
    end
end

function _M.rewrite(conf, ctx)

    local url = ctx.var.uri
    local action = ctx.var.request_method
    local client_ip = ctx.var.http_x_real_ip or core.request.get_ip(ctx)
    local config = conf
    local auth_token, err = get_auth_token(ctx)
    res_init_headers(config)
    if auth_token then
        local res
        if config.hook_cache then
            core.response.set_header("hook-cache", 'cache')
            res = hook_lrucache(plugin_name .. "#" .. auth_token, config.version, get_auth_info, config, ctx, action, url, client_ip, auth_token)
        else
            res = get_auth_info(config, ctx, action, url, client_ip, auth_token)
        end

        if res.status ~= 200 and config.check_termination then
            -- no permission.
            core.response.set_header("Content-Type", "application/json; charset=utf-8")
            return 401, fail_response(res.err, { status_code = 401 })
        end

        local data
        if res.body then
            data = res.body.data
            if type(data) == "table" then
                res_to_headers(config, data)
            end
        end

    elseif config.check_termination then
        core.response.set_header("Content-Type", "application/json; charset=utf-8")
        return 401, fail_response("Missing auth token in request", { status_code = 401 })
    end
    core.log.info("auth-hook check permission passed")
end

return _M
