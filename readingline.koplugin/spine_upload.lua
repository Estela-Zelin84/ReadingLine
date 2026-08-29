local DataStorage = require("datastorage")
local QRMessage = require("ui/widget/qrmessage")
local UIManager = require("ui/uimanager")
local lfs = require("libs/libkoreader-lfs")
local socket = require("socket")

local M = { active = nil }
local MAX_BYTES = 10 * 1024 * 1024

local function mkdir(path)
    if lfs.attributes(path, "mode") ~= "directory" then lfs.mkdir(path) end
end

local function networkAddress()
    -- Prefer the source address selected by the current routing table. This
    -- follows DHCP/network changes and does not assume that Wi-Fi is called
    -- wlan0 on every device.
    local p = io.popen("ip -4 route get 1.1.1.1 2>/dev/null")
    if p then
        local out = p:read("*a") or ""
        p:close()
        local ip = out:match("%ssrc%s+(%d+%.%d+%.%d+%.%d+)")
        local dev = out:match("%sdev%s+([%w_.%-]+)")
        if ip and dev and not ip:match("^127%.") then return ip, dev end
    end

    -- Fallback for devices without a default route (for example, a local
    -- hotspot with no Internet route): choose a global non-loopback address.
    p = io.popen("ip -4 -o addr show scope global 2>/dev/null")
    if not p then return nil end
    local out = p:read("*a") or ""
    p:close()
    for line in out:gmatch("[^\n]+") do
        local dev, ip = line:match("^%d+:%s+([^%s]+).*inet%s+(%d+%.%d+%.%d+%.%d+)/")
        if dev and ip and not ip:match("^127%.") and not ip:match("^169%.254%.") then
            return ip, dev
        end
    end
    return nil
end

local function commandSucceeded(command)
    local ok, why, code = os.execute(command)
    return ok == true or ok == 0 or (why == "exit" and code == 0)
end

-- Kindle images commonly default INPUT to DROP. Open only the selected
-- temporary port, and remove exactly that rule when the upload ends. On
-- devices without iptables or with an ACCEPT policy this is a no-op.
local function openFirewallPort(port, dev)
    local p = io.popen("iptables -L INPUT -n 2>/dev/null")
    if not p then return true, false end
    local rules = p:read("*a") or ""
    p:close()
    if not rules:match("Chain INPUT %(policy DROP%)") then return true, false end
    if rules:find("dpt:" .. tostring(port), 1, true) then return true, false end

    local iface = dev and dev:match("^[%w_.%-]+$")
    local command = "iptables -I INPUT 1"
        .. (iface and (" -i " .. iface) or "")
        .. " -p tcp --dport " .. tostring(port) .. " -j ACCEPT 2>/dev/null"
    if commandSucceeded(command) then return true, true end
    return false, false
end

local function closeFirewallPort(state)
    if not state or not state.firewall_added then return end
    local iface = state.interface and state.interface:match("^[%w_.%-]+$")
    local command = "iptables -D INPUT"
        .. (iface and (" -i " .. iface) or "")
        .. " -p tcp --dport " .. tostring(state.port)
        .. " -j ACCEPT 2>/dev/null"
    commandSucceeded(command)
    state.firewall_added = false
end

local function response(client, code, body)
    local status = code == 200 and "200 OK" or "400 Bad Request"
    client:send("HTTP/1.1 " .. status .. "\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\nContent-Length: " .. #body .. "\r\n\r\n" .. body)
    client:close()
end

local function uploadPage()
    return [[<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>上传书脊</title><style>body{font-family:sans-serif;max-width:520px;margin:40px auto;padding:20px}button,input{font-size:18px;margin:14px 0;width:100%}button{padding:12px}</style><h2>上传自定义书脊</h2><p>请选择手机相册中的图片，最大 10 MB。</p><form method="post" enctype="multipart/form-data"><input type="file" name="image" accept="image/jpeg,image/png,image/webp" required><button>上传到 Kindle</button></form>]]
end

local function extractImage(body, content_type)
    local boundary = content_type and content_type:match("boundary=([^;]+)")
    if not boundary then return nil, "缺少上传边界" end
    boundary = boundary:gsub('^"', ''):gsub('"$', '')
    local header_end = body:find("\r\n\r\n", 1, true)
    if not header_end then return nil, "上传格式错误" end
    local part_headers = body:sub(1, header_end - 1)
    local data_start = header_end + 4
    local data_end = body:find("\r\n--" .. boundary, data_start, true)
    if not data_end then return nil, "图片不完整" end
    local mime = part_headers:match("[Cc]ontent%-[Tt]ype:%s*([^\r\n]+)") or ""
    local ext = mime:find("png", 1, true) and ".png"
        or mime:find("webp", 1, true) and ".webp" or ".jpg"
    return body:sub(data_start, data_end - 1), ext
end

function M.stop()
    local s = M.active
    if not s then return end
    M.active = nil
    closeFirewallPort(s)
    if s.client then pcall(s.client.close, s.client) end
    if s.server then pcall(s.server.close, s.server) end
    if s.tick then UIManager:unschedule(s.tick) end
    if s.qr then pcall(function() UIManager:close(s.qr) end) end
end

function M.start(book_path, on_uploaded)
    M.stop()
    local ip, dev = networkAddress()
    if not ip then return nil, "Kindle 尚未连接 Wi‑Fi" end
    local server, port
    -- 8080 is commonly pre-authorised on Kindle images. If occupied, use a
    -- temporary high port and open only that port in the local firewall.
    local candidates = { 8080 }
    for candidate = 18080, 18089 do candidates[#candidates + 1] = candidate end
    local firewall_added = false
    for _, candidate in ipairs(candidates) do
        server = socket.bind("0.0.0.0", candidate, 1)
        if server then
            local allowed, added = openFirewallPort(candidate, dev)
            if allowed then
                port = candidate
                firewall_added = added
                break
            end
            pcall(server.close, server)
            server = nil
        end
    end
    if not server then return nil, "无法开启临时上传服务" end
    server:settimeout(0)
    math.randomseed(os.time() + #book_path)
    local token = string.format("%08x", math.random(0, 0x3fffffff))
    local state = {
        server=server, port=port, interface=dev, firewall_added=firewall_added,
        token=token, header_buffer="", body_chunks={}, body_size=0,
        headers=nil, content_length=nil, method=nil, request_path=nil,
        started=os.time(),
    }
    M.active = state

    local function finish(path)
        M.stop()
        if on_uploaded then on_uploaded(path) end
    end
    state.tick = function()
        if M.active ~= state then return end
        if os.time() - state.started > 120 then M.stop(); return end
        if not state.client then
            state.client = state.server:accept()
            if state.client then state.client:settimeout(0) end
        end
        local c = state.client
        if c then
            local chunk, err, partial = c:receive(8192)
            chunk = chunk or partial
            if chunk and #chunk > 0 then
                if not state.headers then
                    state.header_buffer = state.header_buffer .. chunk
                    local hs, he = state.header_buffer:find("\r\n\r\n", 1, true)
                    if hs then
                        local headers = state.header_buffer:sub(1, hs - 1)
                        state.method, state.request_path = headers:match("^(%u+)%s+([^%s]+)")
                        state.content_length = tonumber(headers:match("[Cc]ontent%-[Ll]ength:%s*(%d+)")) or 0
                        state.headers = headers
                        local remainder = state.header_buffer:sub(he + 1)
                        -- Keep this as an empty string: the same upload
                        -- session accepts a follow-up request after the phone
                        -- first loads the form page.
                        state.header_buffer = ""
                        if #remainder > 0 then
                            state.body_chunks[#state.body_chunks + 1] = remainder
                            state.body_size = #remainder
                        end
                    end
                else
                    state.body_chunks[#state.body_chunks + 1] = chunk
                    state.body_size = state.body_size + #chunk
                end
            end
            if state.body_size > MAX_BYTES + 65536 then
                response(c, 400, "图片过大")
                state.client, state.headers, state.body_chunks = nil, nil, {}
                state.header_buffer = ""
                state.body_size = 0
            else
                local method, path = state.method, state.request_path
                local length = state.content_length or 0
                if method == "GET" and state.headers then
                    response(c, path == "/" .. token and 200 or 400, path == "/" .. token and uploadPage() or "链接无效")
                    state.client, state.headers, state.body_chunks = nil, nil, {}
                    state.header_buffer = ""
                    state.body_size = 0
                elseif method == "POST" and path == "/" .. token and state.body_size >= length then
                        local content_type = state.headers:match("[Cc]ontent%-[Tt]ype:%s*([^\r\n]+)")
                        local body = table.concat(state.body_chunks)
                        local image, ext = extractImage(body:sub(1, length), content_type)
                        if image and #image <= MAX_BYTES then
                            local dir = DataStorage:getSettingsDir() .. "/simplebookshelf_spines"
                            mkdir(dir)
                            local name = state.token .. ext
                            local target = dir .. "/" .. name
                            local f = io.open(target, "wb")
                            if f then
                                f:write(image)
                                f:close()
                                response(c, 200, "<h2>上传成功，可以关闭此页面。</h2>")
                                -- Drop the multipart body before repainting the
                                -- shelf. On Scribe this avoids keeping a large
                                -- phone upload alive while ImageWidget decodes it.
                                state.body_chunks = {}
                                state.body_size = 0
                                body, image = nil, nil
                                collectgarbage("collect")
                                finish(target)
                                return
                            end
                        end
                        response(c, 400, "图片上传失败")
                        state.client, state.headers, state.body_chunks = nil, nil, {}
                        state.header_buffer = ""
                        state.body_size = 0
                elseif err and err ~= "timeout" then
                    c:close(); state.client, state.headers, state.body_chunks = nil, nil, {}
                    state.header_buffer = ""
                    state.body_size = 0
                end
            end
        end
        UIManager:scheduleIn(0.05, state.tick)
    end
    UIManager:scheduleIn(0.05, state.tick)
    local url = "http://" .. ip .. ":" .. port .. "/" .. token
    local qr = QRMessage:new{ text=url, width=require("device").screen:scaleBySize(520), height=require("device").screen:scaleBySize(520), timeout=120, dismiss_callback=function() M.stop() end }
    state.qr = qr
    UIManager:show(qr)
    return url
end

return M
