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
local core      = require("apisix.core")
local upstream  = require("apisix.upstream")
local ipmatcher = require("resty.ipmatcher")
local bit       = require("bit")
local ngx       = ngx
local str_byte  = string.byte
local str_sub   = string.sub


local schema = {
    type = "object",
    properties = {
        protocol_name = {type = "string"},
        protocol_level = {type = "integer"},
        upstream = {
            type = "object",
            properties = {
                ip = {type = "string"}, -- deprecated, use "host" instead
                host = {type = "string"},
                port = {type = "number"},
            },
            oneOf = {
                {required = {"host", "port"}},
                {required = {"ip", "port"}},
            },
        }
    },
    required = {"protocol_name", "protocol_level"},
}


local plugin_name = "mqtt-proxy"


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


local function decode_variable_byte_int(data, offset)
    local multiplier = 1
    local len = 0
    local pos
    for i = offset, offset + 3 do
        pos = i
        local byte = str_byte(data, i, i)
        len = len + bit.band(byte, 127) * multiplier
        multiplier = multiplier * 128
        if bit.band(byte, 128) == 0 then
            break
        end
    end

    return len, pos
end


local function parse_msg_hdr(data)
    local packet_type_flags_byte = str_byte(data, 1, 1)
    if packet_type_flags_byte < 16 or packet_type_flags_byte > 32 then
        return nil, nil,
            "Received unexpected MQTT packet type+flags: " .. packet_type_flags_byte
    end

    local len, pos = decode_variable_byte_int(data, 2)
    return len, pos
end


local function parse_mqtt(data, parsed_pos)
    local res = {}

    local protocol_len = str_byte(data, parsed_pos + 1, parsed_pos + 1) * 256
                         + str_byte(data, parsed_pos + 2, parsed_pos + 2)
    parsed_pos = parsed_pos + 2
    res.protocol = str_sub(data, parsed_pos + 1, parsed_pos + protocol_len)
    parsed_pos = parsed_pos + protocol_len

    res.protocol_ver = str_byte(data, parsed_pos + 1, parsed_pos + 1)
    parsed_pos = parsed_pos + 1

    -- skip control flags & keepalive
    parsed_pos = parsed_pos + 3

    if res.protocol_ver == 5 then
        -- skip properties
        local property_len
        property_len, parsed_pos = decode_variable_byte_int(data, parsed_pos + 1)
        parsed_pos = parsed_pos + property_len
    end

    local client_id_len = str_byte(data, parsed_pos + 1, parsed_pos + 1) * 256
                          + str_byte(data, parsed_pos + 2, parsed_pos + 2)
    parsed_pos = parsed_pos + 2

    if parsed_pos + client_id_len > #data then
        res.expect_len = parsed_pos + client_id_len
        return res
    end

    if client_id_len == 0 then
        -- A Server MAY allow a Client to supply a ClientID that has a length of zero bytes
        res.client_id = ""
    else
        res.client_id = str_sub(data, parsed_pos + 1, parsed_pos + client_id_len)
    end

    parsed_pos = parsed_pos + client_id_len

    res.expect_len = parsed_pos
    return res
end


function _M.preread(conf, ctx)
    local sock = ngx.req.socket()
    -- the header format of MQTT CONNECT can be found in
    -- https://docs.oasis-open.org/mqtt/mqtt/v5.0/os/mqtt-v5.0-os.html#_Toc3901033
    local data, err = sock:peek(5)
    if not data then
        core.log.error("failed to read the msg header: ", err)
        return 503
    end

    local remain_len, pos, err = parse_msg_hdr(data)
    if not remain_len then
        core.log.error("failed to parse the msg header: ", err)
        return 503
    end

    local data, err = sock:peek(pos + remain_len)
    if not data then
        core.log.error("failed to read the Connect Command: ", err)
        return 503
    end

    local res = parse_mqtt(data, pos)
    if res.expect_len > #data then
        core.log.error("failed to parse mqtt request, expect len: ",
                        res.expect_len, " but got ", #data)
        return 503
    end

    if res.protocol and res.protocol ~= conf.protocol_name then
        core.log.error("expect protocol name: ", conf.protocol_name,
                       ", but got ", res.protocol)
        return 503
    end

    if res.protocol_ver and res.protocol_ver ~= conf.protocol_level then
        core.log.error("expect protocol level: ", conf.protocol_level,
                       ", but got ", res.protocol_ver)
        return 503
    end

    core.log.info("mqtt client id: ", res.client_id)

    if not conf.upstream then
        return
    end

    local host = conf.upstream.host
    if not host then
        host = conf.upstream.ip
    end

    if conf.host_is_domain == nil then
        conf.host_is_domain = not ipmatcher.parse_ipv4(host)
                              and not ipmatcher.parse_ipv6(host)
    end

    if conf.host_is_domain then
        local ip, err = core.resolver.parse_domain(host)
        if not ip then
            core.log.error("failed to parse host ", host, ", err: ", err)
            return 503
        end

        host = ip
    end

    local up_conf = {
        type = "roundrobin",
        nodes = {
            {host = host, port = conf.upstream.port, weight = 1},
        }
    }

    local ok, err = upstream.check_schema(up_conf)
    if not ok then
        core.log.error("failed to check schema ", core.json.delay_encode(up_conf),
                       ", err: ", err)
        return 503
    end

    local matched_route = ctx.matched_route
    upstream.set(ctx, up_conf.type .. "#route_" .. matched_route.value.id,
                 ctx.conf_version, up_conf)
    return
end


function _M.log(conf, ctx)
    core.log.info("plugin log phase, conf: ", core.json.encode(conf))
end


return _M
