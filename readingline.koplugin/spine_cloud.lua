-- Shared spine cache using the WebDAV server already configured in KOReader.
-- The configuration is read from settings/cloudstorage.lua on each request,
-- so every device uses its own WebDAV account and application password.
local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local Cloud = {}

local REQUEST_TIMEOUT = 12
local REMOTE_FOLDER = "simplebookshelf/spines"
local enabled_store

function Cloud.configure(store)
    enabled_store = store
end

local function enabled()
    return not enabled_store or enabled_store:readSetting("spine_cloud_enabled") ~= false
end

local function webdavServer()
    local ok, settings = pcall(function()
        return LuaSettings:open(DataStorage:getSettingsDir() .. "/cloudstorage.lua")
    end)
    if not ok or not settings then return nil end
    local servers = settings:readSetting("cs_servers") or {}
    local default_index = settings:readSetting("default_server")
    if default_index and servers[default_index] and servers[default_index].type == "webdav" then
        return servers[default_index]
    end
    for _, server in ipairs(servers) do
        if server.type == "webdav" then return server end
    end
    return nil
end

local function urlJoin(address, path)
    local ok, util = pcall(require, "util")
    local encoded = path or ""
    if ok and util and util.urlEncode then encoded = util.urlEncode(encoded, "/") end
    encoded = encoded:gsub("^/+", ""):gsub("/+$", "")
    return address:gsub("/+$", "") .. (encoded ~= "" and "/" .. encoded or "")
end

local function remoteBase(server)
    return urlJoin(server.address, (server.url or "/") .. "/" .. REMOTE_FOLDER)
end

function Cloud.getConfig()
    local server = webdavServer()
    if not server or not enabled() then
        return { configured = false, name = "未找到 KOReader WebDAV 配置" }
    end
    return {
        configured = server.address ~= nil and server.username ~= nil and server.password ~= nil,
        name = server.name or "WebDAV",
        folder = remoteBase(server),
    }
end

function Cloud.isConfigured()
    return Cloud.getConfig().configured == true
end

local function keyFor(book_path)
    local ok, util = pcall(require, "util")
    if ok and util and util.partialMD5 then
        local ok_hash, hash = pcall(util.partialMD5, book_path)
        if ok_hash and type(hash) == "string" and hash ~= "" then return hash end
    end
    return nil
end

function Cloud.keyFor(book_path)
    return keyFor(book_path)
end

local function request(server, url, options)
    local ok, http, ltn12, socket, socketutil = pcall(function()
        return require("socket/http"), require("ltn12"), require("socket"), require("socketutil")
    end)
    if not ok then return nil, "KOReader HTTP 模块不可用" end
    local request_options = {
        url = url,
        method = options.method or "GET",
        headers = options.headers or {},
        user = server.username,
        password = server.password,
        source = options.source,
        sink = options.sink,
    }
    local code, status
    local ok_call = pcall(function()
        socketutil:set_timeout(REQUEST_TIMEOUT, REQUEST_TIMEOUT)
        code, _, status = socket.skip(1, http.request(request_options))
        socketutil:reset_timeout()
    end)
    pcall(function() socketutil:reset_timeout() end)
    if not ok_call then return nil, "坚果云连接失败" end
    return tonumber(code), status
end

local function ensureFolder(server)
    local root = urlJoin(server.address, server.url or "/")
    local first = urlJoin(root .. "/", "simplebookshelf")
    local second = urlJoin(first .. "/", "spines")
    for _, url in ipairs({ first, second }) do
        local code = request(server, url, {
            method = "MKCOL",
            headers = { ["Content-Length"] = "0" },
        })
        if code ~= 201 and code ~= 405 and code ~= 301 and code ~= 207 then
            return nil, "无法创建共享书脊文件夹（HTTP " .. tostring(code or "连接失败") .. "）"
        end
    end
    return true
end

local function extension(path)
    local ext = path:match("%.([%w]+)$")
    ext = ext and ext:lower()
    return (ext == "jpeg" and "jpg") or ext or "jpg"
end

local function shellQuote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function remotePath(server, key, ext)
    return urlJoin(remoteBase(server) .. "/", key .. "." .. ext)
end

function Cloud.upload(book_path, local_path)
    if not Cloud.isConfigured() then return nil, "当前设备没有 KOReader WebDAV 配置" end
    local server = webdavServer()
    local key = keyFor(book_path)
    if not key then return nil, "无法生成书籍指纹" end
    local file = io.open(local_path, "rb")
    if not file then return nil, "找不到本地书脊图片" end
    local size = file:seek("end") or 0
    file:seek("set", 0)
    local ok_folder, folder_err = ensureFolder(server)
    if not ok_folder then pcall(function() file:close() end); return nil, folder_err end
    local code = request(server, remotePath(server, key, extension(local_path)), {
        method = "PUT",
        headers = { ["Content-Length"] = tostring(size), ["Content-Type"] = "application/octet-stream" },
        source = require("ltn12").source.file(file),
    })
    pcall(function() file:close() end)
    if code and code >= 200 and code <= 299 then return true end
    return nil, "上传共享书脊失败（HTTP " .. tostring(code or "连接失败") .. "）"
end

function Cloud.download(book_path, cache_dir)
    if not Cloud.isConfigured() then return nil, "当前设备没有 KOReader WebDAV 配置" end
    local server = webdavServer()
    local key = keyFor(book_path)
    if not key then return nil, "无法生成书籍指纹" end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(cache_dir, "mode") ~= "directory" then lfs.mkdir(cache_dir) end
    for _, ext in ipairs({ "jpg", "png", "webp", "bmp", "gif" }) do
        local target = cache_dir .. "/" .. key .. "." .. ext
        local temp = target .. ".tmp"
        local file = io.open(temp, "wb")
        if file then
            local code = request(server, remotePath(server, key, ext), {
                method = "GET",
                sink = require("ltn12").sink.file(file),
            })
            pcall(function() file:close() end)
            if code == 200 then
                pcall(os.remove, target)
                if os.rename(temp, target) then return target end
            end
            pcall(os.remove, temp)
        end
    end
    return nil, "共享库中没有这本书的书脊"
end

-- Download outside KOReader's UI thread. LuaSocket's HTTP request is
-- synchronous; on a Kindle a slow WebDAV/TLS response can otherwise make the
-- whole reader look dead for up to several timeout periods.
function Cloud.downloadAsync(book_path, cache_dir, on_done)
    if not Cloud.isConfigured() then
        if on_done then on_done(nil, "当前设备没有 KOReader WebDAV 配置") end
        return false
    end
    local server = webdavServer()
    local key = keyFor(book_path)
    if not key then
        if on_done then on_done(nil, "无法生成书籍指纹") end
        return false
    end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(cache_dir, "mode") ~= "directory" then lfs.mkdir(cache_dir) end

    local job = cache_dir .. "/." .. key .. ".download"
    local status = job .. ".status"
    pcall(os.remove, status)
    for _, ext in ipairs({ "jpg", "png", "webp", "bmp", "gif" }) do
        pcall(os.remove, job .. "." .. ext)
    end

    local credentials = shellQuote((server.username or "") .. ":" .. (server.password or ""))
    local commands = {}
    for _, ext in ipairs({ "jpg", "png", "webp", "bmp", "gif" }) do
        local temp = job .. "." .. ext
        local url = remotePath(server, key, ext)
        commands[#commands + 1] = "if /usr/bin/curl --silent --show-error --fail --connect-timeout 4 --max-time 8 -u "
            .. credentials .. " -o " .. shellQuote(temp) .. " " .. shellQuote(url)
            .. " >/dev/null 2>&1; then printf " .. shellQuote(ext) .. " > " .. shellQuote(status)
            .. "; exit 0; fi; rm -f " .. shellQuote(temp)
    end
    commands[#commands + 1] = "printf 'ERR' > " .. shellQuote(status)
    local command = "( " .. table.concat(commands, "; ") .. " ) >/dev/null 2>&1 &"
    local ok = os.execute(command)
    if not (ok == true or ok == 0) then
        if on_done then on_done(nil, "无法启动后台下载") end
        return false
    end

    local started = os.time()
    local function poll()
        local f = io.open(status, "rb")
        local result = f and f:read("*a") or nil
        if f then f:close() end
        if result and result ~= "" then
            local target
            if result ~= "ERR" then
                local temp = job .. "." .. result
                target = cache_dir .. "/" .. key .. "." .. result
                pcall(os.remove, target)
                if not os.rename(temp, target) then target = nil end
            end
            pcall(os.remove, status)
            if on_done then on_done(target, target and nil or "共享库中没有这本书的书脊") end
            return
        end
        if os.time() - started >= 45 then
            pcall(os.remove, status)
            for _, ext in ipairs({ "jpg", "png", "webp", "bmp", "gif" }) do pcall(os.remove, job .. "." .. ext) end
            if on_done then on_done(nil, "共享库连接超时") end
            return
        end
        UIManager:scheduleIn(0.25, poll)
    end
    UIManager:scheduleIn(0.25, poll)
    return true
end

function Cloud.test()
    if not Cloud.isConfigured() then return nil, "没有找到 KOReader WebDAV 配置" end
    return ensureFolder(webdavServer())
end

return Cloud
