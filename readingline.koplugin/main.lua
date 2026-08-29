local BB = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local Device = require("device")
local Dispatcher = require("dispatcher")
local Geom = require("ui/geometry")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local LuaSettings = require("luasettings")
local Utf8Proc = require("ffi/utf8proc")
-- This development line owns its navigation bar.  It deliberately does not
-- load or register with SimpleUI.

local Screen = Device.screen
local PLUGIN_DIR = debug.getinfo(1, "S").source:sub(2):match("^(.*)/[^/]+$") or "."
-- Keep the navigation surface proportional across Kindle, Kobo and desktop
-- test devices; the lower bound only protects very small screens.
local NAVBAR_HEIGHT = math.max(42, math.floor(Screen:getHeight() * .051))
-- Showcase uses the same four physical shadow depths as the bookshelf. The
-- front cover adds a fixed five-degree lean; this table controls only the
-- right-side depth selected in 陈列架 → 立体度 → 书本.
local DEPTH_BY_LEVEL = { 3, 6, 10, 15 }
-- Use one face size for every level of this plugin's KOReader menus.  This
-- matches the 16pt book titles on the day ticket and prevents nested menus
-- from falling back to KOReader's larger per-page defaults.
local PLUGIN_MENU_FONT_SIZE = 16
-- KOReader's statistics database records time and page movement, but not a
-- word/character counter.  The approved web ticket used roughly 260 Chinese
-- characters per displayed page (186 pages -> 4.9万字), so keep that as the
-- default while allowing an advanced setting to override it later.
local READING_WORDS_PER_PAGE = 260
local store = LuaSettings:open(DataStorage:getSettingsDir() .. "/simplebookshelf.lua")
local Cloud = dofile(PLUGIN_DIR .. "/spine_cloud.lua")
Cloud.configure(store)
local function cloudConfigured()
    local ok, value = pcall(Cloud.isConfigured)
    return ok and value == true
end

-- SimpleUI 2.5.0 moved its modules under infra/, features/, and screens/.
-- Keep one resolver for every integration point in this plugin: mixing the
-- new modules with the old root-level aliases creates a second Config/QA
-- registry and makes external navbar actions disappear when a shelf opens.
local GLOBAL_DEFAULTS = {
    sort_mode = "status",
    book_3d_level = 2,
    shelf_3d_level = 2,
    shelf_thickness = 24,
    shelf_rows = 3,
    embedded_font_size = 15,
    embedded_line_spacing = 30,
    standalone_font_size = 13,
    standalone_line_spacing = 34,
    book_left_margin_level = 2,
    book_right_margin_level = 2,
    book_top_margin_level = 3,
    scan_depth = 8,
    book_scale = 100,
    book_open_mode = "single",
}

-- Showcase owns a separate geometry namespace.  It shares book metadata with
-- the bookshelf, but never shares shelf spacing, wall or depth settings.
local SHOWCASE_DEFAULTS = {
    rows = 3,
    book_gap = 10,
    depth = 3,
    book_depth = 3,
    shelf_depth = 3,
    shelf_thickness = 8,
    margin_left = 48,
    margin_right = 48,
    sort_mode = "status",
    book_scale = 100,
    wallpaper_fit_mode = "fill",
    filter = "all",
}

local function globalSetting(key)
    local value = store:readSetting(key)
    if value == nil then return GLOBAL_DEFAULTS[key] end
    return value
end

local function saveGlobal(key, value)
    store:saveSetting(key, value)
    store:flush()
end

local function showcaseSetting(key)
    local value = store:readSetting("showcase_" .. key)
    if value == nil then return SHOWCASE_DEFAULTS[key] end
    return value
end

local function saveShowcase(key, value)
    store:saveSetting("showcase_" .. key, value)
    store:flush()
end

local NAV_TABS = {"home", "bookshelf", "stats", "showcase"}
local NAV_TAB_LABELS = {home="阅读主页", bookshelf="书柜", stats="统计", showcase="陈列架"}
local function navigationOrder()
    local saved = store:readSetting("navigation_order")
    local result, seen = {}, {}
    if type(saved) == "table" then
        for _, tab in ipairs(saved) do
            if NAV_TAB_LABELS[tab] and not seen[tab] then result[#result + 1] = tab; seen[tab] = true end
        end
    end
    for _, tab in ipairs(NAV_TABS) do
        if not seen[tab] then result[#result + 1] = tab; seen[tab] = true end
    end
    return result
end
local function saveNavigationOrder(order)
    store:saveSetting("navigation_order", order); store:flush()
end
local function navigationTabEnabled(tab)
    local value = store:readSetting("navigation_" .. tab)
    if value == nil then return tab ~= "home" end
    return value == true
end
local function enabledNavigationTabs()
    local result = {}
    for _, tab in ipairs(navigationOrder()) do
        if navigationTabEnabled(tab) then result[#result + 1] = tab end
    end
    if #result == 0 then result[1] = "bookshelf" end
    return result
end
local function statsOptionEnabled(view)
    local value = store:readSetting("stats_option_" .. view)
    return value == nil and true or value == true
end
local function enabledStatsViews()
    local result = {}
    for _, view in ipairs({"day", "week", "month", "year", "screen"}) do
        if statsOptionEnabled(view) then result[#result + 1] = view end
    end
    if #result == 0 then result[1] = "day" end
    return result
end

local function pluginEnabled()
    return store:readSetting("enabled") ~= false
end

local function setPluginEnabled(enabled)
    store:saveSetting("enabled", enabled == true)
    store:flush()
end

local function readingWordsPerPageSetting()
    -- Compatibility fallback used only until a text index is available.
    -- It is intentionally fixed and no longer exposed as a user setting.
    return READING_WORDS_PER_PAGE
end

local TEXT_BOOK_EXTENSIONS = {
    epub=true, fb2=true, txt=true, html=true, htm=true,
    mobi=true, azw=true, azw3=true, doc=true, docx=true, rtf=true,
    chm=true, md=true, markdown=true, xhtml=true,
}

local function isReadingLineTextBook(path)
    local ext = tostring(path or ""):lower():match("%.([^%.%/\\]+)$")
    return ext and TEXT_BOOK_EXTENSIONS[ext] == true
end

local function readingLineCountTextChars(text)
    text = tostring(text or "")
    if text == "" then return 0 end
    -- Count readable letters/numbers/Han characters, not layout whitespace,
    -- ASCII punctuation or common CJK punctuation. This makes illustration,
    -- blank and chapter-divider pages naturally contribute little or nothing.
    text = text:gsub("[%s%c]", ""):gsub("[%p]", "")
    for _, mark in ipairs({"，","。","！","？","；","：","、","‘","’","“","”","（","）","《","》","〈","〉","【","】","〔","〕","［","］","｛","｝","…","—","·","～","￥"}) do
        text = text:gsub(mark, "")
    end
    local count, ok = Utf8Proc.count(text)
    return ok and math.max(0, tonumber(count) or 0) or 0
end

local function readingLineTextIndexKey(md5, pages)
    md5 = tostring(md5 or "")
    pages = math.max(0, tonumber(pages) or 0)
    if md5 == "" or pages <= 0 then return nil end
    return md5 .. ":" .. tostring(math.floor(pages + .5))
end

local function readingLineFontFace()
    return store:readSetting("reading_line_font") or "cfont"
end

local function standardizePluginMenu(menu)
    if not menu then return menu end
    local size = PLUGIN_MENU_FONT_SIZE
    menu.items_font_size = size
    menu.items_mandatory_font_size = size
    menu.items_per_page = menu.items_per_page or 8
    -- Menu uses one Menu object for nested sub_item_table pages.  Hook the
    -- page switch as well, so a second/third/fourth level cannot fall back to
    -- KOReader's default font after the first level was standardized.
    if menu.switchItemTable and not menu._simplebookshelf_font_hooked then
        local switchItemTable = menu.switchItemTable
        menu.switchItemTable = function(self, ...)
            self.items_font_size = size
            self.items_mandatory_font_size = size
            self.font_size = nil
            self.infont_size = nil
            local result = switchItemTable(self, ...)
            self.items_font_size = size
            self.items_mandatory_font_size = size
            self.font_size = nil
            self.infont_size = nil
            if self.updateItems then pcall(self.updateItems, self) end
            return result
        end
        menu._simplebookshelf_font_hooked = true
    end
    -- Clear the cached values and rebuild MenuItem widgets.  Recalculating
    -- dimensions alone does not replace the small widgets created by Menu:init.
    menu.font_size = nil
    menu.infont_size = nil
    if menu.updateItems then
        pcall(menu.updateItems, menu)
    elseif menu._recalculateDimen then
        pcall(menu._recalculateDimen, menu)
    end
    return menu
end

-- Anchor page-level settings to the same column as the active bottom
-- navigation item.  This keeps the popup visually attached to its page
-- instead of appearing as an unrelated centered dialog.
local function navColumnMenuGeometry(tab, height_ratio)
    local screen_width, screen_height = Screen:getWidth(), Screen:getHeight()
    local tabs = enabledNavigationTabs()
    local index = 1
    for i, value in ipairs(tabs) do if value == tab then index = i; break end end
    local cell = math.floor(screen_width / #tabs)
    local left = (index - 1) * cell
    local width = index == #tabs and screen_width - left or cell
    local height = math.floor(screen_height * (height_ratio or .72))
    return {
        x = left,
        y = math.max(0, screen_height - NAVBAR_HEIGHT - height),
        width = width,
        height = height,
    }
end

local function libraryRoot()
    return store:readSetting("library_root")
        or G_reader_settings:readSetting("home_dir")
        or "/mnt/us/documents"
end

local function loadOverrides()
    local value = store:readSetting("book_overrides")
    return type(value) == "table" and value or {}
end

local book_overrides = loadOverrides()

-- Showcase appearance is a separate namespace.  Shared book metadata is
-- allowed, but cover/spine geometry from the bookshelf must never leak into
-- the display cabinet.
local function loadShowcaseOverrides()
    local value = store:readSetting("showcase_book_overrides")
    return type(value) == "table" and value or {}
end

local showcase_overrides = loadShowcaseOverrides()

local function saveShowcaseOverrides()
    store:saveSetting("showcase_book_overrides", showcase_overrides)
    store:flush()
end

local function saveOverrides()
    store:saveSetting("book_overrides", book_overrides)
    store:flush()
end

local function closeSwitchBlocker()
    local blocker = UIManager._simpleui_external_switch_blocker
    if blocker then
        UIManager._simpleui_external_switch_blocker = nil
        pcall(function() UIManager:close(blocker) end)
    end
end

-- The shelf owns its wallpaper completely. It deliberately does not require
-- SimpleUI's old homescreen module or its split wallpaper feature: those two
-- implementations used different settings and caches, which was the source
-- of the selectable-but-blank wallpaper state.
local WALLPAPER_DEFAULT_DIR = DataStorage:getSettingsDir() .. "/simplebookshelf/wallpapers"

local function ensureDirectory(path)
    if lfs.attributes(path, "mode") == "directory" then return path end
    local parent = path:match("^(.*)/[^/]+$")
    if parent and parent ~= path then ensureDirectory(parent) end
    lfs.mkdir(path)
    return path
end

local function wallpaperDir()
    local path = store:readSetting("wallpaper_dir")
    if type(path) ~= "string" or path == "" then path = WALLPAPER_DEFAULT_DIR end
    if path ~= "/" then path = path:gsub("/+$", "") end
    return ensureDirectory(path)
end

local function setWallpaperDir(path)
    if type(path) ~= "string" or path == "" then path = WALLPAPER_DEFAULT_DIR end
    if path ~= "/" then path = path:gsub("/+$", "") end
    ensureDirectory(path)
    store:saveSetting("wallpaper_dir", path)
    -- A wallpaper selected from the previous directory must never silently
    -- remain active after the directory changes.
    store:saveSetting("wallpaper_path", false)
    store:saveSetting("wallpaper_enabled", false)
    store:flush()
end

local function wallpaperPath()
    local path = store:readSetting("wallpaper_path")
    if path == false then return nil end
    return type(path) == "string" and path or nil
end

local function setWallpaperPath(path)
    store:saveSetting("wallpaper_path", path or false)
    store:flush()
end

local function wallpaperEnabled()
    return store:readSetting("wallpaper_enabled") == true and wallpaperPath() ~= nil
end

local function setWallpaperEnabled(enabled)
    store:saveSetting("wallpaper_enabled", enabled ~= false)
    store:flush()
end

local function wallpaperFitMode()
    local mode = store:readSetting("wallpaper_fit_mode")
    if mode == "original" or mode == "stretch" or mode == "fill" then return mode end
    return "fill"
end

local function setWallpaperFitMode(mode)
    if mode ~= "original" and mode ~= "stretch" and mode ~= "fill" then mode = "fill" end
    store:saveSetting("wallpaper_fit_mode", mode)
    store:flush()
end

local SHOWCASE_WALLPAPER_DIR = DataStorage:getSettingsDir() .. "/simplebookshelf/showcase-wallpapers"
local function showcaseWallpaperDir()
    local path = store:readSetting("showcase_wallpaper_dir") or SHOWCASE_WALLPAPER_DIR
    return ensureDirectory(path)
end
local function showcaseWallpaperPath()
    local path = store:readSetting("showcase_wallpaper_path")
    return type(path) == "string" and path ~= "" and path or nil
end
local function showcaseWallpaperEnabled()
    return store:readSetting("showcase_wallpaper_enabled") == true and showcaseWallpaperPath() ~= nil
end
local function showcaseWallpaperFitMode()
    local mode = store:readSetting("showcase_wallpaper_fit_mode") or store:readSetting("showcase_wallpaper_fit")
    if mode == "original" or mode == "stretch" or mode == "fill" then return mode end
    return "fill"
end
local function scanWallpapersAt(dir)
    local items, exts = {}, {jpg=true, jpeg=true, png=true, bmp=true, gif=true, webp=true}
    if lfs.attributes(dir, "mode") == "directory" then
        for fname in lfs.dir(dir) do
            local ext = fname:match("%.([^%.]+)$")
            if ext and exts[ext:lower()] then items[#items+1] = {label=fname, path=dir .. "/" .. fname} end
        end
    end
    table.sort(items, function(a,b) return a.label:lower() < b.label:lower() end)
    return items
end

local function scanWallpapers()
    local dir = wallpaperDir()
    local items = {}
    local exts = { jpg=true, jpeg=true, png=true, bmp=true, gif=true, webp=true }
    if lfs.attributes(dir, "mode") == "directory" then
        for fname in lfs.dir(dir) do
            if fname ~= "." and fname ~= ".." then
                local ext = fname:match("%.([^%.]+)$")
                if ext and exts[ext:lower()] then
                    items[#items + 1] = {
                        label = fname:match("^(.+)%.[^%.]+$") or fname,
                        path = dir .. "/" .. fname,
                    }
                end
            end
        end
        table.sort(items, function(a, b) return a.label:lower() < b.label:lower() end)
    end
    return items
end

local function buildWallpaperWidget(path, width, height, fit_override)
    if not path or lfs.attributes(path, "mode") ~= "file" then return nil end
    local ImageWidget = require("ui/widget/imagewidget")
    local fit = fit_override or wallpaperFitMode()
    local ok, widget = pcall(function()
        if fit == "stretch" then
            return ImageWidget:new{file=path, width=width, height=height, alpha=true}
        end
        local probe = ImageWidget:new{file=path, scale_factor=1}
        probe:_render()
        local ow, oh = probe:getOriginalWidth(), probe:getOriginalHeight()
        probe:free()
        if not ow or not oh or ow <= 0 or oh <= 0 then return nil end
        local scale = fit == "fill" and math.max(width / ow, height / oh) or 1
        local image = ImageWidget:new{file=path, scale_factor=scale, alpha=true}
        local CenterContainer = require("ui/widget/container/centercontainer")
        return CenterContainer:new{dimen=Geom:new{w=width, h=height}, image}
    end)
    return ok and widget or nil
end

local function liveFileManager()
    local FM = package.loaded["apps/filemanager/filemanager"]
    return FM and FM.instance or nil
end

local function applicationIsClosing()
    -- _exit_code is assigned by UIManager:quit().  The poweroff/reboot path
    -- broadcasts Close before that assignment, so _entered_poweroff_stage is
    -- needed as the earlier signal too.
    return UIManager._exit_code ~= nil or UIManager._entered_poweroff_stage == true
end

local Shelf
local function closeShelfInstance()
    local shelf = Shelf and Shelf.instance
    if shelf and UIManager:isWidgetShown(shelf) then
        UIManager:close(shelf)
    elseif Shelf then
        Shelf.instance = nil
    end
end

local function openBookThroughFileManager(shelf, path)
    if not path then return false end
    G_reader_settings:delSetting("simplebookshelf_return_pending")
    G_reader_settings:delSetting("simplebookshelf_return_standalone")
    G_reader_settings:delSetting("simplebookshelf_return_page")
    G_reader_settings:saveSetting("simpleui_book_origin", "simplebookshelf")
    G_reader_settings:saveSetting("simplebookshelf_return_tab", shelf and shelf.tab or "bookshelf")
    UIManager._simpleui_book_origin = "simplebookshelf"
    G_reader_settings:flush()
    logger.info("simplebookshelf: opening through FileManager", path)
    if shelf and UIManager:isWidgetShown(shelf) then UIManager:close(shelf) end
    -- Wait until the custom page has actually left UIManager's stack before
    -- creating ReaderUI. This prevents a delayed close of the old home widget
    -- from unwinding the newly-created reader above it.
    UIManager:nextTick(function()
        local fm = liveFileManager()
        if fm and fm.openFile then
            fm:openFile(path)
        else
            require("apps/reader/readerui"):showReader(path)
        end
    end)
    return true
end

local function stableHash(value)
    local hash = 5381
    for i = 1, #value do hash = (hash * 33 + value:byte(i)) % 2147483647 end
    return hash
end

local function defaultBookStyle(path, standalone)
    local h = stableHash(path)
    return {
        width = 48 + (h % 25),
        height_pct = 78 + (math.floor(h / 29) % 19),
        corner = 3 + (math.floor(h / 97) % 5),
        font_size = standalone and globalSetting("standalone_font_size") or globalSetting("embedded_font_size"),
        show_title = true,
        text_color = "white",
        title_vpos = "center",
        line_spacing = standalone and globalSetting("standalone_line_spacing") or globalSetting("embedded_line_spacing"),
        crop_align = "left",
        crop_pct = 20,
        spine_fit = "crop",
    }
end

local function bookStyle(path, standalone)
    local result = defaultBookStyle(path, standalone)
    local override = book_overrides[path]
    if type(override) == "table" then
        for key, value in pairs(override) do result[key] = value end
        -- Migrate the old relative gap setting to an absolute character spacing.
        if override.line_spacing == nil and override.line_gap ~= nil then
            result.line_spacing = math.max(result.font_size or 15, (result.font_size or 15) + override.line_gap)
        end
    end
    return result
end

local function updateBookStyle(path, key, value)
    if type(book_overrides[path]) ~= "table" then book_overrides[path] = {} end
    book_overrides[path][key] = value
    saveOverrides()
end

local function basename(path)
    return (path:match("([^/]+)$") or path):gsub("%.[^%.]+$", "")
end

local function utf8Chars(value)
    local result, i = {}, 1
    while i <= #value do
        local byte = value:byte(i)
        local length = byte < 128 and 1 or (byte < 224 and 2 or (byte < 240 and 3 or 4))
        result[#result + 1] = value:sub(i, i + length - 1)
        i = i + length
    end
    return result
end

local function simpleUIFontFace()
    return readingLineFontFace()
end

-- Translate the locally-rendered page count into a physical-looking spine.
-- Up to 150 pages uses the minimum touch-safe width; thicker books then grow
-- continuously instead of jumping between a few arbitrary presets.  The cap
-- keeps very long omnibuses from consuming an entire shelf row.
local function defaultSpineWidthForPages(pages)
    pages = math.max(0, tonumber(pages) or 0)
    if pages <= 150 then return 57 end
    return math.max(57, math.min(165, math.floor(57 + (pages - 150) * 108 / 750 + .5)))
end

local function showcaseBookStyle(path)
    local style = defaultBookStyle(path, true)
    style.custom_spine = nil
    style.spine_fit = nil
    local override = showcase_overrides[path]
    if type(override) == "table" then
        for key, value in pairs(override) do style[key] = value end
    end
    return style
end

-- Read the cover embedded in the book metadata through KOReader itself.
-- This deliberately does not depend on SimpleUI: SimpleUI's cover cache/API
-- may be absent or return nil on KPW6 even when the EPUB metadata contains a
-- valid cover.
local COVER_CACHE_BYTE_BUDGET = 12 * 1024 * 1024
local cover_widget_cache = {}
local cover_cache_order = {}
local cover_cache_bytes = 0
-- Cover extraction opens the document provider and can take hundreds of
-- milliseconds on low-power Kindles. Cache the already-scaled thumbnail,
-- never the original multi-megapixel cover, and run one extraction per UI
-- turn so opening the showcase cannot monopolize the event loop.
local cover_load_state = {}
local cover_load_queue = {}
local cover_loader_running = false

local function coverCacheKey(path, w, h)
    path = tostring(path or ""):gsub("^file://", "")
    local mtime = tonumber(lfs.attributes(path, "modification")) or 0
    return path .. "\0" .. tostring(math.max(1, w)) .. "x" .. tostring(math.max(1, h)) .. "@" .. tostring(mtime), path
end

local function coverBufferBytes(bb)
    if not bb then return 0 end
    local ok, bytes = pcall(function()
        local height = bb:getHeight()
        local stride = tonumber(bb.stride)
        if stride then return stride * height end
        return bb:getWidth() * height * math.max(1, math.ceil((bb:getBpp() or 8) / 8))
    end)
    return ok and bytes or 0
end

local function touchCoverCacheKey(key)
    for i, cached_key in ipairs(cover_cache_order) do
        if cached_key == key then table.remove(cover_cache_order, i); break end
    end
    cover_cache_order[#cover_cache_order + 1] = key
end

local function putCoverThumbnail(key, bb)
    local previous = cover_widget_cache[key]
    if previous then cover_cache_bytes = math.max(0, cover_cache_bytes - coverBufferBytes(previous)) end
    cover_widget_cache[key] = bb
    cover_cache_bytes = cover_cache_bytes + coverBufferBytes(bb)
    touchCoverCacheKey(key)
    while cover_cache_bytes > COVER_CACHE_BYTE_BUDGET and #cover_cache_order > 1 do
        local oldest = table.remove(cover_cache_order, 1)
        local evicted = cover_widget_cache[oldest]
        cover_widget_cache[oldest] = nil
        cover_load_state[oldest] = nil
        cover_cache_bytes = math.max(0, cover_cache_bytes - coverBufferBytes(evicted))
        -- Drop our reference only. A just-painted ImageWidget may still own a
        -- live reference until the current repaint has fully unwound.
    end
end

local function getBookCoverWidget(path, w, h, align, fast_only)
    local key
    key, path = coverCacheKey(path, w, h)
    if path == "" or not lfs.attributes(path, "mode") then
        cover_load_state[key] = "missing"
        return nil
    end
    local cached = cover_widget_cache[key]
    if cached then
        cover_load_state[key] = "ready"
        touchCoverCacheKey(key)
        local ImageWidget = require("ui/widget/imagewidget")
        local ok_cached, widget = pcall(ImageWidget.new, ImageWidget, {
            image=cached, image_disposable=false,
            width=math.max(1, w), height=math.max(1, h),
            scale_factor=1,
        })
        if ok_cached and widget then return widget end
    end
    -- Fast path: reuse SimpleUI/KOReader's persisted cover thumbnail when it
    -- already exists. This avoids opening and parsing the EPUB/PDF at all.
    local ok_shared, shared = pcall(require, "modules/module_books_shared")
    if ok_shared and shared and shared.getBookCover then
        local ok_fast, fast_widget = pcall(shared.getBookCover,
            path, math.max(1, w), math.max(1, h), align or "center", nil)
        if ok_fast and fast_widget then
            cover_load_state[key] = "ready"
            return fast_widget
        end
    end
    -- CoverBrowser already keeps compressed, device-sized cover images in
    -- bookinfo_cache.sqlite3.  On stock KOReader there is no
    -- modules/module_books_shared, so skipping this cache used to make the
    -- showcase open every EPUB/PDF one by one.  Reuse the persisted BB first:
    -- decompressing and scaling a thumbnail is dramatically cheaper than
    -- opening the document provider and also makes the whole first page paint
    -- in one pass when CoverBrowser has indexed the library.
    local ok_bim, BIM = pcall(require, "bookinfomanager")
    if not ok_bim then
        ok_bim, BIM = pcall(require, "plugins/coverbrowser.koplugin/bookinfomanager")
    end
    if ok_bim and BIM and BIM.getBookInfo then
        local ok_info, info = pcall(BIM.getBookInfo, BIM, path, true)
        local source_bb = ok_info and info and info.cover_bb
        if source_bb then
            local target_bb
            local ImageWidget = require("ui/widget/imagewidget")
            local ok_target = pcall(function()
                target_bb = BB.new(math.max(1, w), math.max(1, h), source_bb:getType())
                target_bb:fill(BB.COLOR_WHITE)
                local scaler = ImageWidget:new{
                    image=source_bb, image_disposable=false,
                    width=math.max(1, w), height=math.max(1, h),
                }
                scaler:paintTo(target_bb, 0, 0)
                if scaler.free then scaler:free() end
            end)
            if source_bb.free then pcall(source_bb.free, source_bb) end
            if ok_target and target_bb then
                putCoverThumbnail(key, target_bb)
                cover_load_state[key] = "ready"
                return getBookCoverWidget(path, w, h, align, true)
            end
        end
    end
    -- Callers painting a complete page may stop after memory/persisted-cache
    -- lookup.  A miss is then decoded by the cooperative queue, never inside
    -- the page-switch paint pass.
    if fast_only then return nil end
    local ok_registry, DocumentRegistry = pcall(require, "document/documentregistry")
    if not ok_registry or not DocumentRegistry then
        cover_load_state[key] = "missing"
        return nil
    end
    local ok_doc, doc = pcall(DocumentRegistry.openDocument, DocumentRegistry, path)
    if not ok_doc or not doc then
        cover_load_state[key] = "missing"
        return nil
    end
    local ok_load = true
    if doc.loadDocument then ok_load = pcall(doc.loadDocument, doc, false) end
    local ok_cover, cover_bb = false, nil
    if ok_load and doc.getCoverPageImage then
        ok_cover, cover_bb = pcall(doc.getCoverPageImage, doc)
    end
    if not ok_cover or not cover_bb then
        if doc.close then pcall(doc.close, doc) end
        cover_load_state[key] = "missing"
        return nil
    end
    local ImageWidget = require("ui/widget/imagewidget")
    local target_bb
    local ok_target = pcall(function()
        target_bb = BB.new(math.max(1, w), math.max(1, h), cover_bb:getType())
        target_bb:fill(BB.COLOR_WHITE)
        local scaler = ImageWidget:new{
            image=cover_bb, image_disposable=false,
            width=math.max(1, w), height=math.max(1, h),
        }
        scaler:paintTo(target_bb, 0, 0)
        if scaler.free then scaler:free() end
    end)
    if doc.close then pcall(doc.close, doc) end
    if cover_bb.free then pcall(cover_bb.free, cover_bb) end
    if not ok_target or not target_bb then
        cover_load_state[key] = "missing"
        return nil
    end
    putCoverThumbnail(key, target_bb)
    cover_load_state[key] = "ready"
    return getBookCoverWidget(path, w, h, align)
end

-- Bookshelf spines deliberately use crop-to-fill. This path is separate from
-- the showcase's full-cover thumbnail path: a narrow spine must take a slice
-- from the artwork, never squeeze the whole front cover into a thin strip.
local function getBookSpineWidget(path, w, h, align, cache_only)
    local base_key
    base_key, path = coverCacheKey(path, w, h)
    local key = "crop\0" .. base_key .. "\0" .. tostring(align or "center")
    local cached = cover_widget_cache[key]
    if cached then
        touchCoverCacheKey(key)
        local ImageWidget = require("ui/widget/imagewidget")
        local ok_widget, widget = pcall(ImageWidget.new, ImageWidget, {
            image=cached, image_disposable=false,
            width=math.max(1, w), height=math.max(1, h), scale_factor=1,
        })
        if ok_widget then return widget end
    end
    -- HOME should never block its first paint while a document is opened and
    -- decoded.  Callers using cache_only get an immediate miss and can queue
    -- the crop for the cooperative loader below.
    if cache_only then return nil end
    if path == "" or lfs.attributes(path, "mode") ~= "file" then return nil end

    local source_bb
    local ok_bim, BIM = pcall(require, "bookinfomanager")
    if not ok_bim then ok_bim, BIM = pcall(require, "plugins/coverbrowser.koplugin/bookinfomanager") end
    if ok_bim and BIM and BIM.getBookInfo then
        local ok_info, info = pcall(BIM.getBookInfo, BIM, path, true)
        if ok_info and info and info.has_cover and info.cover_bb then source_bb = info.cover_bb end
    end
    if not source_bb then
        local ok_registry, DocumentRegistry = pcall(require, "document/documentregistry")
        if ok_registry and DocumentRegistry then
            local ok_doc, doc = pcall(DocumentRegistry.openDocument, DocumentRegistry, path)
            if ok_doc and doc then
                local ok_load = not doc.loadDocument or pcall(doc.loadDocument, doc, false)
                if ok_load and doc.getCoverPageImage then
                    local ok_cover, extracted = pcall(doc.getCoverPageImage, doc)
                    if ok_cover then source_bb = extracted end
                end
                if doc.close then pcall(doc.close, doc) end
            end
        end
    end
    if not source_bb then return nil end

    local target_bb
    local ok_crop = pcall(function()
        local sw, sh = source_bb:getWidth(), source_bb:getHeight()
        local scale = math.max(w / math.max(1, sw), h / math.max(1, sh))
        local scaled_w = math.max(w, math.ceil(sw * scale))
        local scaled_h = math.max(h, math.ceil(sh * scale))
        local filled = source_bb:scale(scaled_w, scaled_h)
        target_bb = BB.new(math.max(1, w), math.max(1, h), filled:getType())
        local x_off
        if align == "left" then x_off = 0
        elseif align == "right" then x_off = math.max(0, scaled_w - w)
        else x_off = math.max(0, math.floor((scaled_w - w) / 2)) end
        local y_off = math.max(0, math.floor((scaled_h - h) / 2))
        target_bb:blitFrom(filled, 0, 0, x_off, y_off, w, h)
        if filled ~= source_bb and filled.free then filled:free() end
    end)
    if source_bb.free then pcall(source_bb.free, source_bb) end
    if not ok_crop or not target_bb then return nil end
    putCoverThumbnail(key, target_bb)
    local ImageWidget = require("ui/widget/imagewidget")
    local ok_widget, widget = pcall(ImageWidget.new, ImageWidget, {
        image=target_bb, image_disposable=false,
        width=math.max(1, w), height=math.max(1, h), scale_factor=1,
    })
    return ok_widget and widget or nil
end

local function runNextShowcaseCoverLoad()
    local item = table.remove(cover_load_queue, 1)
    if not item then
        cover_loader_running = false
        return
    end
    if cover_load_state[item.key] == "pending" then
        local widget = getBookCoverWidget(item.path, item.w, item.h, "center")
        if widget and widget.free then widget:free() end
    end
    local shelf = item.shelf
    if shelf and shelf._showcase_cover_pending then
        local page = item.page or 1
        local remaining = math.max(0, (shelf._showcase_cover_pending[page] or 1) - 1)
        shelf._showcase_cover_pending[page] = remaining > 0 and remaining or nil
        -- Do not expose asynchronous extraction one book at a time.  The
        -- current paint turn queues every miss before this worker runs; wait
        -- for that page's final item, then repaint once so the covers arrive
        -- together like the bookshelf and HOME page.
        if remaining == 0 and shelf == Shelf.instance and shelf.tab == "showcase"
                and (shelf.page or 1) == page then
            UIManager:setDirty(shelf, "ui")
        end
    end
    UIManager:scheduleIn(.03, runNextShowcaseCoverLoad)
end

local function queueShowcaseCoverLoad(shelf, path, w, h, rect)
    local key, clean_path = coverCacheKey(path, w, h)
    if clean_path == "" or cover_widget_cache[key] or cover_load_state[key] == "pending" or cover_load_state[key] == "missing" then return end
    cover_load_state[key] = "pending"
    local page = shelf and (shelf.page or 1) or 1
    if shelf then
        shelf._showcase_cover_pending = shelf._showcase_cover_pending or {}
        shelf._showcase_cover_pending[page] = (shelf._showcase_cover_pending[page] or 0) + 1
    end
    cover_load_queue[#cover_load_queue + 1] = {
        key=key, path=clean_path, w=math.max(1, w), h=math.max(1, h), shelf=shelf, rect=rect, page=page,
    }
    if not cover_loader_running then
        cover_loader_running = true
        UIManager:scheduleIn(.03, runNextShowcaseCoverLoad)
    end
end

local home_crop_queue, home_crop_pending, home_crop_running = {}, {}, false
local function runNextHomeCropLoad()
    local item = table.remove(home_crop_queue, 1)
    if not item then home_crop_running = false; return end
    local widget = getBookSpineWidget(item.path, item.w, item.h, item.align, false)
    home_crop_pending[item.key] = nil
    if item.shelf and item.shelf == Shelf.instance and item.shelf.tab == "home" and item.rect then
        local cached = item.shelf._home_render_cache
        if widget and cached and cached.bb and item.generation == (item.shelf._home_render_generation or 0) then
            pcall(widget.paintTo, widget, cached.bb, item.rect.x, item.rect.y)
        end
        UIManager:setDirty(item.shelf, function() return "ui", item.rect, false end)
    end
    if widget and widget.free then widget:free() end
    UIManager:scheduleIn(.03, runNextHomeCropLoad)
end

local function queueHomeCropLoad(shelf, path, w, h, align, rect)
    local base_key, clean_path = coverCacheKey(path, w, h)
    local key = "crop\0" .. base_key .. "\0" .. tostring(align or "center")
    if clean_path == "" or home_crop_pending[key] or cover_widget_cache[key] then return end
    home_crop_pending[key] = true
    home_crop_queue[#home_crop_queue + 1] = {
        key=key, path=clean_path, w=math.max(1,w), h=math.max(1,h),
        align=align or "center", shelf=shelf, rect=rect,
        generation=shelf and shelf._home_render_generation or 0,
    }
    if not home_crop_running then
        home_crop_running = true
        UIManager:scheduleIn(.03, runNextHomeCropLoad)
    end
end

local home_cover_queue, home_cover_pending, home_cover_running = {}, {}, false
local function runNextHomeCoverLoad()
    local item = table.remove(home_cover_queue,1)
    if not item then home_cover_running=false; return end
    local widget=getBookCoverWidget(item.path,item.w,item.h,item.align,false)
    home_cover_pending[item.key]=nil
    if item.shelf and item.shelf==Shelf.instance and item.shelf.tab=="home" and item.rect then
        local cached=item.shelf._home_render_cache
        if widget and cached and cached.bb and item.generation==(item.shelf._home_render_generation or 0) then
            pcall(widget.paintTo,widget,cached.bb,item.rect.x,item.rect.y)
        end
        UIManager:setDirty(item.shelf,function() return "ui",item.rect,false end)
    end
    if widget and widget.free then widget:free() end
    UIManager:scheduleIn(.03,runNextHomeCoverLoad)
end

local function queueHomeCoverLoad(shelf,path,w,h,align,rect)
    local key,clean_path=coverCacheKey(path,w,h)
    if clean_path=="" or home_cover_pending[key] or cover_widget_cache[key] or cover_load_state[key]=="missing" then return end
    home_cover_pending[key]=true
    home_cover_queue[#home_cover_queue+1]={key=key,path=clean_path,w=math.max(1,w),h=math.max(1,h),align=align or "center",shelf=shelf,rect=rect,generation=shelf and shelf._home_render_generation or 0}
    if not home_cover_running then home_cover_running=true; UIManager:scheduleIn(.03,runNextHomeCoverLoad) end
end

local function updateShowcaseBookStyle(path, key, value)
    if type(showcase_overrides[path]) ~= "table" then showcase_overrides[path] = {} end
    showcase_overrides[path][key] = value
    saveShowcaseOverrides()
end

local function showcaseBookDimensions(book, row_h, scale)
    local style = showcaseBookStyle(book.path)
    local individual = math.max(.75, math.min(1.35, (style.width or 65) / 65))
    local h = math.max(60, math.floor((row_h - 16) * 0.66 * scale * individual))
    h = math.min(row_h - 12, h)
    -- Default front covers keep their aspect ratio; width is derived from
    -- height and never adjusted independently.
    local w = math.max(42, math.floor(h * 0.67))
    return w, h
end

local function showcaseBookProjection(h)
    local level = math.max(1, math.min(4, tonumber(showcaseSetting("book_depth")) or 2))
    local lean = math.max(2, math.floor(h * 0.0874886635 + .5)) -- tan(5°)
    return lean, DEPTH_BY_LEVEL[level], level
end

local TEXT_COLORS = {
    white = BB.COLOR_WHITE,
    pale = BB.COLOR_GRAY_E,
    light = BB.COLOR_GRAY_C,
    medium = BB.COLOR_GRAY_8,
    dark = BB.COLOR_GRAY_4,
    black = BB.COLOR_BLACK,
}

local function drawText(bb, value, x, y, size, bold, max_width, color)
    local Font = require("ui/font")
    local TextWidget = require("ui/widget/textwidget")
    value = tostring(value or "")
    size = math.max(6, math.floor(size or 12))
    if max_width then
        local probe = TextWidget:new{
            text = value,
            face = Font:getFace(simpleUIFontFace(), size),
            bold = bold,
            fgcolor = color or BB.COLOR_BLACK,
        }
        local measured = probe:getSize()
        probe:free()
        if measured and measured.w and measured.w > max_width then
            size = math.max(6, math.floor(size * max_width / measured.w))
        end
    end
    local options = {
        text = value,
        face = Font:getFace(simpleUIFontFace(), size),
        bold = bold,
        fgcolor = color or BB.COLOR_BLACK,
    }
    local widget = TextWidget:new(options)
    widget:paintTo(bb, x, y)
    widget:free()
end

local function drawPluginIcon(bb, filename, x, y, size)
    local ImageWidget = require("ui/widget/imagewidget")
    local path = PLUGIN_DIR .. "/train-icons-svg/" .. filename
    if not lfs.attributes(path, "mode") then return end
    local ok, widget = pcall(function()
        return ImageWidget:new{file=path, width=size, height=size, alpha=true, file_do_cache=false}
    end)
    if ok and widget then
        pcall(widget.paintTo, widget, bb, x, y)
        if widget.free then widget:free() end
    end
end

local function drawCenteredText(bb, value, x, y, size, bold, width, color)
    value = tostring(value or "")
    local measured = 0
    for _, ch in ipairs(utf8Chars(value)) do
        -- KOReader's fallback font is approximately 1em for CJK and .6em
        -- for the mono/Latin glyphs used by this stub.
        measured = measured + (ch:byte(1) >= 128 and size or size * .6)
    end
    if measured > width and measured > 0 then
        size = math.max(6, math.floor(size * width / measured))
        measured = 0
        for _, ch in ipairs(utf8Chars(value)) do
            measured = measured + (ch:byte(1) >= 128 and size or size * .6)
        end
    end
    drawText(bb, value, math.floor(x + (width - measured) / 2), y, size, bold, nil, color)
end

local function drawCenteredTextMeasured(bb, value, x, y, size, bold, width, color)
    local Font = require("ui/font")
    local TextWidget = require("ui/widget/textwidget")
    value = tostring(value or "")
    size = math.max(6, math.floor(size or 12))
    local widget, measured
    for _ = 1, 2 do
        widget = TextWidget:new{text=value, face=Font:getFace(simpleUIFontFace(), size), bold=bold, fgcolor=color or BB.COLOR_BLACK}
        measured = widget:getSize()
        if measured and measured.w and measured.w > width and size > 6 then
            widget:free()
            size = math.max(6, math.floor(size * width / measured.w))
            widget = nil
        else
            break
        end
    end
    if not widget then
        widget = TextWidget:new{text=value, face=Font:getFace(simpleUIFontFace(), size), bold=bold, fgcolor=color or BB.COLOR_BLACK}
        measured = widget:getSize()
    end
    local measured_width = measured and measured.w or 0
    widget:paintTo(bb, math.floor(x + (width - measured_width) / 2), y)
    widget:free()
end

local function drawRightAlignedTextMeasured(bb, value, right, y, size, bold, width, color)
    local Font = require("ui/font")
    local TextWidget = require("ui/widget/textwidget")
    value = tostring(value or "")
    size = math.max(6, math.floor(size or 12))
    local widget, measured
    for _ = 1, 2 do
        widget = TextWidget:new{text=value, face=Font:getFace(simpleUIFontFace(), size), bold=bold, fgcolor=color or BB.COLOR_BLACK}
        measured = widget:getSize()
        if measured and measured.w and measured.w > width and size > 6 then
            widget:free()
            size = math.max(6, math.floor(size * width / measured.w))
            widget = nil
        else
            break
        end
    end
    if not widget then
        widget = TextWidget:new{text=value, face=Font:getFace(simpleUIFontFace(), size), bold=bold, fgcolor=color or BB.COLOR_BLACK}
        measured = widget:getSize()
    end
    local measured_width = math.min(width, measured and measured.w or 0)
    widget:paintTo(bb, math.floor(right - measured_width), y)
    widget:free()
end

local function metadataText(value)
    if value == nil then return "" end
    if type(value) == "string" or type(value) == "number" then
        return tostring(value)
    end
    if type(value) ~= "table" then return "" end
    local parts = {}
    for _, item in pairs(value) do
        local text = metadataText(item)
        if text ~= "" then parts[#parts + 1] = text end
    end
    return table.concat(parts, " ")
end

local function selectedBookMetadata(data)
    local fields = {
        "language", "lang", "book_language", "dc_language",
        "tags", "tag", "keywords", "keyword", "subjects", "subject",
        "categories", "category", "genre", "genres", "description",
        "comments", "series",
    }
    local parts = {}
    for _, key in ipairs(fields) do
        local value = data[key]
        if value ~= nil then
            local text = metadataText(value)
            if text ~= "" then parts[#parts + 1] = text end
        end
    end
    return table.concat(parts, " ")
end

local function bookInfo(path, history_map)
    local book = {
        path = path,
        title = basename(path),
        authors = "",
        language = "",
        metadata_text = "",
        percent = 0,
        status = 2,
        added = lfs.attributes(path, "modification") or 0,
        last_read = history_map[path] or 0,
        pages = 0,
    }
    local ok_shared, shared = pcall(require, "desktop_modules/module_books_shared")
    if ok_shared and shared and shared.getBookData then
        local ok_data, data = pcall(shared.getBookData, path)
        if ok_data and type(data) == "table" then
            book.title = data.title or book.title
            book.authors = data.authors or data.author or ""
            book.language = tostring(data.language or data.lang or data.book_language or data.dc_language or "")
            book.metadata_text = selectedBookMetadata(data)
            book.percent = data.percent or 0
            book.pages = tonumber(data.pages or data.total_pages or data.page_count or data.doc_pages) or 0
        end
    end
    local ok_doc, DocSettings = pcall(require, "docsettings")
    if ok_doc then
        local ok_settings, settings = pcall(DocSettings.open, DocSettings, path)
        if ok_settings and settings then
            local summary = settings:readSetting("summary") or {}
            if book.percent == 0 then book.percent = settings:readSetting("percent_finished") or 0 end
            if book.pages <= 0 then
                book.pages = tonumber(settings:readSetting("doc_pages")
                    or settings:readSetting("page_count")
                    or settings:readSetting("pages")) or 0
            end
            book.status = (summary.status == "complete" or book.percent >= 0.995) and 3
                or (book.percent > 0 and 1 or 2)
            pcall(function() settings:close() end)
        end
    end
    local ov = book_overrides[book.path]
    if ov and ov.title_override and ov.title_override ~= "" then book.title = ov.title_override end
    return book
end

-- KOReader stores highlights and notes in the document settings file.  Keep
-- this lookup defensive because older documents may not have annotations yet.
local function bookHighlights(path)
    local ok_doc, DocSettings = pcall(require, "docsettings")
    if not ok_doc then return {} end
    local ok_settings, settings = pcall(DocSettings.open, DocSettings, path)
    if not ok_settings or not settings then return {} end
    local raw = settings:readSetting("bookmarks") or settings:readSetting("annotations") or {}
    pcall(function() settings:close() end)
    local result = {}
    if type(raw) ~= "table" then return result end
    for _, item in ipairs(raw) do
        if type(item) == "table" then
            local text = item.text or item.note or item.highlight or item.title
            if text and tostring(text) ~= "" then
                result[#result + 1] = {text=tostring(text), page=item.page or item.pageno or item.page_number}
            end
        end
    end
    return result
end

local function showcaseFilterLabel(key)
    if key == "language:zh" then return "语言：中文" end
    if key == "language:en" then return "语言：英文" end
    if key == "topic:feminism" then return "主题：女性主义" end
    if key and key:sub(1, 8) == "keyword:" then
        return "关键词：" .. key:sub(9)
    end
    return "全部书籍"
end

local function bookLanguage(book)
    local declared = tostring(book.language or "") .. " " .. tostring(book.metadata_text or "")
    local lower = declared:lower()
    if lower:find("中文", 1, true) or lower:find("汉语", 1, true)
            or lower:find("chinese", 1, true) or lower:find("zh%-cn") then
        return "zh"
    end
    if lower:find("英文", 1, true) or lower:find("英语", 1, true)
            or lower:find("english", 1, true) or lower:find("en%-us") then
        return "en"
    end
    local source = tostring(book.title or "") .. " " .. tostring(book.path or "")
    local has_cjk, has_latin = false, false
    for _, ch in ipairs(utf8Chars(source)) do
        local byte = ch:byte(1) or 0
        if byte >= 0xE0 and byte <= 0xEF then has_cjk = true end
        if (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122) then has_latin = true end
    end
    if has_cjk then return "zh" end
    if has_latin then return "en" end
    return nil
end

local function bookSearchText(book)
    return (tostring(book.title or "") .. " " .. tostring(book.authors or "") .. " "
        .. tostring(book.path or "") .. " " .. tostring(book.language or "") .. " "
        .. tostring(book.metadata_text or "")):lower()
end

local FEMINISM_TERMS = {
    "女性主义", "女权", "妇女", "性别研究", "性别平等", "feminism", "feminist",
    "women's studies", "womens studies", "gender studies",
}

local function historyMap()
    local result = {}
    local ok, history = pcall(require, "readhistory")
    if not ok or not history then return result end
    if not history.hist or #history.hist == 0 then pcall(function() history:reload() end) end
    for index, entry in ipairs(history.hist or {}) do
        if entry and entry.file then result[entry.file] = entry.time or entry.datetime or (#history.hist - index) end
    end
    return result
end

local function scanBooks(root)
    local DocumentRegistry = require("document/documentregistry")
    local result, hmap = {}, historyMap()
    local function walk(directory, depth)
        if depth > globalSetting("scan_depth") then return end
        local ok, iterator, state = pcall(lfs.dir, directory)
        if not ok then return end
        for name in iterator, state do
            if name ~= "." and name ~= ".." and name ~= ".sdr" and name:sub(1, 1) ~= "." then
                local path = directory .. "/" .. name
                local mode = lfs.attributes(path, "mode")
                if mode == "directory" then
                    walk(path, depth + 1)
                elseif mode == "file" and DocumentRegistry:hasProvider(path) then
                    result[#result + 1] = bookInfo(path, hmap)
                end
            end
        end
    end
    walk(root, 0)
    return result
end

local function scanBooksAsync(root, done)
    local DocumentRegistry = require("document/documentregistry")
    local result, hmap = {}, historyMap()
    local processed = 0
    local function walk(directory, depth)
        if depth > globalSetting("scan_depth") then return end
        local ok, iterator, state = pcall(lfs.dir, directory)
        if not ok then return end
        for name in iterator, state do
            if name ~= "." and name ~= ".." and name ~= ".sdr" and name:sub(1, 1) ~= "." then
                local path = directory .. "/" .. name
                local mode = lfs.attributes(path, "mode")
                if mode == "directory" then
                    walk(path, depth + 1)
                elseif mode == "file" and DocumentRegistry:hasProvider(path) then
                    result[#result + 1] = bookInfo(path, hmap)
                end
                processed = processed + 1
                if processed % 8 == 0 then coroutine.yield() end
            end
        end
    end
    local worker = coroutine.create(function()
        walk(root, 0)
        done(result)
    end)
    local function step()
        local ok, err = coroutine.resume(worker)
        if not ok then
            logger.warn("simplebookshelf: incremental scan failed:", err)
            done(nil)
            return
        end
        if coroutine.status(worker) ~= "dead" then UIManager:scheduleIn(.02, step) end
    end
    UIManager:nextTick(step)
end

-- Keep the expensive recursive scan out of navigation. A compact copy is
-- persisted so the shelf can paint immediately after KOReader starts; a
-- delayed rescan then reconciles newly imported books and reading progress.
local scan_cache = {}
local function cachedBooks(root)
    local memory = scan_cache[root]
    if memory then return memory end
    local saved = store:readSetting("scan_cache")
    if type(saved) == "table" and saved.root == root and type(saved.books) == "table" then
        scan_cache[root] = saved.books
        return saved.books
    end
    scan_cache[root] = {}
    return scan_cache[root]
end

local function booksSignature(books)
    local parts = {}
    for _, book in ipairs(books or {}) do
        parts[#parts + 1] = table.concat({
            book.path or "", book.added or 0, book.last_read or 0,
            book.status or 0, book.percent or 0, book.pages or 0, book.title or "",
        }, "\31")
    end
    table.sort(parts)
    return table.concat(parts, "\30")
end

local function sortBooks(books)
    local mode = globalSetting("sort_mode")
    table.sort(books, function(a, b)
        if mode == "title" then return a.title:lower() < b.title:lower() end
        if mode == "added" then return a.added == b.added and a.title < b.title or a.added > b.added end
        if mode == "read" then return a.last_read == b.last_read and a.title < b.title or a.last_read > b.last_read end
        if a.status ~= b.status then return a.status < b.status end
        if a.status == 1 and a.percent ~= b.percent then return a.percent > b.percent end
        return a.title:lower() < b.title:lower()
    end)
end

local function spinner(title, value, min_value, max_value, step, callback)
    local SpinWidget = require("ui/widget/spinwidget")
    UIManager:show(SpinWidget:new{
        title_text = title,
        value = value,
        value_min = min_value,
        value_max = max_value,
        value_step = step or 1,
        default_value = value,
        ok_text = "应用",
        cancel_text = "取消",
        callback = function(widget) callback(widget.value) end,
    })
end

-- Re-evaluate every visible menu's dynamic text_func/checked_func after a value
-- changes. KOReader only repaints a menu on setDirty("ui"); it does not rebuild
-- the item widgets, so labels driven by text_func would stay stale (showing the
-- default or previously-cached value) until the menu is reopened. Walking the
-- window stack and calling updateItems() on the topmost Menu forces a rebuild
-- of its item labels, which also covers nested submenus.
local function refreshTopMenu()
    local stack = UIManager._window_stack
    if not stack then return end
    for i = #stack, 1, -1 do
        local widget = stack[i] and stack[i].widget
        if widget and type(widget.updateItems) == "function" and widget.item_table then
            widget:updateItems()
            UIManager:setDirty(widget, "ui")
            return
        end
    end
end

local ShelfCanvas = WidgetContainer:extend{}
function ShelfCanvas:getSize() return Geom:new{ w = self.width, h = self.height } end

local SOFTNESS_BY_LEVEL = { 12, 8, 4, 2 }
-- These are alpha-mask strengths, not opaque paint colours. The shadow is
-- composited over the wallpaper so its original tone remains visible.
local CORE_MASK_BY_LEVEL = {
    BB.COLOR_GRAY_4, BB.COLOR_GRAY_8, BB.COLOR_GRAY_B, BB.COLOR_GRAY_E,
}
local FEATHER_MASK_BY_LEVEL = {
    { BB.COLOR_GRAY_3, BB.COLOR_GRAY_2, BB.COLOR_GRAY_1 },
    { BB.COLOR_GRAY_6, BB.COLOR_GRAY_4, BB.COLOR_GRAY_2, BB.COLOR_GRAY_1 },
    { BB.COLOR_GRAY_8, BB.COLOR_GRAY_5, BB.COLOR_GRAY_2 },
    { BB.COLOR_GRAY_A, BB.COLOR_GRAY_4 },
}

local function dimensionalValues(key)
    local level = math.max(1, math.min(4, globalSetting(key) or 2))
    return DEPTH_BY_LEVEL[level], SOFTNESS_BY_LEVEL[level], CORE_MASK_BY_LEVEL[level], FEATHER_MASK_BY_LEVEL[level]
end

local blend_mask, blend_mask_w, blend_mask_h
local function blendRect(target_bb, x, y, w, h, alpha_mask)
    if w <= 0 or h <= 0 then return end
    if not blend_mask or w > blend_mask_w or h > blend_mask_h then
        if blend_mask and blend_mask.free then blend_mask:free() end
        blend_mask_w = math.max(w, blend_mask_w or 0)
        blend_mask_h = math.max(h, blend_mask_h or 0)
        blend_mask = BB.new(blend_mask_w, blend_mask_h, BB.TYPE_BB8)
    end
    if not blend_mask then return end
    blend_mask:paintRect(0, 0, w, h, alpha_mask)
    target_bb:colorblitFromRGB32(blend_mask, x, y, 0, 0, w, h, BB.COLOR_BLACK)
end

local function paintSoftShadow(bb, x, y, w, h, depth, softness, core_color, feather_colors)
    -- Older settings files may contain a missing/invalid 3D level.  Treat
    -- that as no shadow instead of aborting the whole KOReader repaint.
    depth = tonumber(depth) or 0
    if depth <= 0 then return end
    softness = math.max(0, softness or 0)
    local colors = feather_colors or { BB.COLOR_GRAY_A, BB.COLOR_GRAY_C, BB.COLOR_GRAY_E }
    -- A dark contact shadow followed by increasingly pale one-pixel bands
    -- gives the e-ink panel a visibly feathered edge instead of a hard offset.
    blendRect(bb, x + w, y + depth, depth, math.max(1, h - depth), core_color or BB.COLOR_GRAY_8)
    blendRect(bb, x + depth, y + h, math.max(1, w - depth), depth, core_color or BB.COLOR_GRAY_8)
    for band = 1, softness do
        local color_index = math.min(#colors, math.max(1, math.ceil(band * #colors / math.max(1, softness))))
        local color = colors[color_index]
        local offset = depth + band
        blendRect(bb, x + w + depth + band - 1, y + offset, 1, math.max(1, h - offset), color)
        blendRect(bb, x + offset, y + h + depth + band - 1, math.max(1, w - offset), 1, color)
    end
end

local function paintTopRoundedWidget(widget, target_bb, x, y, w, h, radius)
    radius = math.max(0, math.min(radius or 0, math.floor(math.min(w, h) / 2)))
    if radius == 0 then widget:paintTo(target_bb, x, y); return end
    local tmp = BB.new(w, h, target_bb:getType())
    if not tmp then widget:paintTo(target_bb, x, y); return end
    tmp:fill(BB.COLOR_WHITE)
    widget:paintTo(tmp, 0, 0)
    local function insetAt(row)
        if row >= radius then return 0 end
        local dy = radius - row
        return math.max(0, math.ceil(radius - math.sqrt(math.max(0, radius * radius - dy * dy))))
    end
    local row = 0
    while row < h do
        local inset = insetAt(row)
        local run = 1
        while row + run < h and insetAt(row + run) == inset do run = run + 1 end
        local span = w - inset * 2
        if span > 0 then target_bb:blitFrom(tmp, x + inset, y + row, inset, row, span, run) end
        row = row + run
    end
    tmp:free()
end

local function paintBookEdgeHighlight(bb, x, y, w, h, level, corner)
    level = tonumber(level) or 1
    if level < 2 then return end
    local colors = { BB.COLOR_GRAY_E, BB.COLOR_GRAY_C, BB.COLOR_GRAY_A, BB.COLOR_GRAY_8 }
    local bands = math.min(#colors, level - 1)
    local top = y + math.max(2, corner or 0)
    local height = math.max(1, h - math.max(2, corner or 0))
    for band = 1, bands do
        -- Brightest at the book/shadow boundary, fading softly into the cover.
        bb:paintRect(x + w - band, top, 1, height, colors[band])
    end
end

local function paintShelfEdgeHighlight(bb, x, y, w, level)
    level = tonumber(level) or 1
    if level < 2 then return end
    local colors = { BB.COLOR_GRAY_E, BB.COLOR_GRAY_C, BB.COLOR_GRAY_A }
    local bands = math.min(#colors, level - 1)
    for band = 1, bands do
        -- Brightest at the shelf/shadow boundary, fading upward into the shelf.
        bb:paintRect(x, y - band, w, 1, colors[band])
    end
end

local function customSpineWidget(path, w, h, fit)
    if not path or lfs.attributes(path, "mode") ~= "file" then return nil end
    local ImageWidget = require("ui/widget/imagewidget")
    local ok, widget = pcall(function()
        -- Do not probe/render the original phone photo first. ImageWidget's
        -- scale_factor path decodes the native image and only then scales it,
        -- which can retain several multi-megapixel buffers on Scribe. Passing
        -- the target dimensions makes RenderImage downsample during decode.
        -- The shelf card is narrow enough that the tiny aspect-ratio tradeoff
        -- is preferable to a memory spike and keeps all uploaded formats safe.
        return ImageWidget:new{
            file=path, width=w, height=h, alpha=true, file_do_cache=false,
        }
    end)
    return ok and widget or nil
end


-- Paint a front cover as a very slightly right-leaning parallelogram. The
-- bottom edge remains on its shelf position while the top shifts by tan(5°).
-- Row blits preserve the real cover image instead of replacing it with a
-- decorative polygon.
local function paintSkewedWidget(widget, target_bb, x, y, w, h, lean)
    local tmp = BB.new(w, h, target_bb:getType())
    if not tmp then widget:paintTo(target_bb, x, y); return end
    tmp:fill(BB.COLOR_WHITE)
    widget:paintTo(tmp, 0, 0)
    local function shiftAt(row)
        if h <= 1 then return lean end
        return math.floor(lean * (h - 1 - row) / (h - 1) + .5)
    end
    local row = 0
    while row < h do
        local shift = shiftAt(row)
        local run = 1
        while row + run < h and shiftAt(row + run) == shift do run = run + 1 end
        target_bb:blitFrom(tmp, x + shift, y + row, 0, row, w, run)
        row = row + run
    end
    tmp:free()
end

local function paintSkewedBookFace(bb, x, y, w, h, lean, depth, level, side_drop)
    local outer_x = x + w + lean + depth
    local clamped_level = math.max(1, math.min(4, level or 2))
    local side_colors = { BB.COLOR_GRAY_7, BB.COLOR_GRAY_6, BB.COLOR_GRAY_5, BB.COLOR_GRAY_4 }
    -- This is an alpha mask for a black overlay, not a replacement colour.
    -- Keeping it separate from the solid page block lets the rear board show
    -- through the cast shadow (the e-ink equivalent of multiply blending).
    local shadow_masks = { BB.COLOR_GRAY_3, BB.COLOR_GRAY_4, BB.COLOR_GRAY_5, BB.COLOR_GRAY_6 }
    local side_color = side_colors[clamped_level]
    local shadow_mask = shadow_masks[clamped_level]
    side_drop = math.max(1, math.min(8, tonumber(side_drop) or math.floor(depth * .45 + .5)))
    local function dropAt(column)
        if depth <= 1 then return side_drop end
        return math.floor(side_drop * column / (depth - 1) + .5)
    end
    for row = 0, h - 1 do
        local shift = h <= 1 and lean or math.floor(lean * (h - 1 - row) / (h - 1) + .5)
        local inner_x = x + w + shift

        -- The page block falls a few pixels toward the outer edge. Group
        -- columns with the same drop so the sloped side stays inexpensive on
        -- low-memory Kindles while retaining a clean diagonal top/bottom.
        local column = 0
        while column < depth do
            local drop = dropAt(column)
            local run = 1
            while column + run < depth and dropAt(column + run) == drop do run = run + 1 end
            bb:paintRect(inner_x + column, y + row + drop, run, 1, side_color)
            column = column + run
        end
        -- Narrow paper-edge highlight between cover and page block.
        bb:paintRect(inner_x, y + row, 1, 1, BB.COLOR_GRAY_7)
        if depth > 2 then bb:paintRect(inner_x + 1, y + row + dropAt(1), 1, 1, BB.COLOR_GRAY_6) end

        -- Continue a soft cast shadow from the lowered outer page edge.  This
        -- follows the sloped thickness instead of starting from the cover.
        local side_outer = inner_x + depth
        local shadow_w = math.max(1, outer_x - side_outer + math.floor(side_drop * .7))
        if shadow_w > 0 then
            blendRect(bb, side_outer, y + row + side_drop, shadow_w, 1, shadow_mask)
        end
    end
    -- A short descending contact shadow grounds the book and continues the
    -- direction established by the sloped page block.
    for band = 0, 3 do
        blendRect(bb, x + depth + band, y + h + band,
            math.max(1, w + lean + side_drop - band), 1,
            band < 2 and BB.COLOR_GRAY_4 or BB.COLOR_GRAY_3)
    end
    return outer_x
end

local function paintShowcaseSeamHighlight(bb, x, seam_y, w)
    if w <= 0 then return end
    -- Five one-pixel bands: a bright center with a fast fade into each plane.
    bb:paintRect(x, seam_y - 3, w, 1, BB.COLOR_GRAY_5)
    bb:paintRect(x, seam_y - 2, w, 1, BB.COLOR_GRAY_6)
    bb:paintRect(x, seam_y - 1, w, 1, BB.COLOR_GRAY_7)
    bb:paintRect(x, seam_y,     w, 1, BB.COLOR_GRAY_6)
    bb:paintRect(x, seam_y + 1, w, 1, BB.COLOR_GRAY_5)
end

function ShelfCanvas:paintTo(bb, origin_x, origin_y)
    local owner, width = self.owner, self.width
    local height = owner.content_height or (self.height - NAVBAR_HEIGHT)
    -- Book spines are painted after the shelf-board block below, so these
    -- values must live for the whole paint pass.  Keeping them inside the
    -- `bookshelf` branch made every spine receive nil shadow parameters.
    local book_shadow, book_soft, book_core, book_feather
    local book_3d_level
    if owner.tab == "bookshelf" then
        book_shadow, book_soft, book_core, book_feather = dimensionalValues("book_3d_level")
        book_3d_level = math.max(1, math.min(4, globalSetting("book_3d_level") or 2))
    end
    bb:paintRect(origin_x, origin_y, width, height, BB.COLOR_WHITE)
    owner:paintWallpaper(bb, origin_x, origin_y)
    owner.hit_books = {}
    if owner.tab == "bookshelf" then
        local rows = math.max(1, math.min(5, globalSetting("shelf_rows") or 3))
        local row_height = math.floor(height / rows)
        local shelf_shadow, shelf_soft, shelf_core, shelf_feather = dimensionalValues("shelf_3d_level")
        local shelf_3d_level = math.max(1, math.min(4, globalSetting("shelf_3d_level") or 2))
        local shelf_thickness = globalSetting("shelf_thickness")
        for row = 1, rows do
            local top = origin_y + (row - 1) * row_height
            local baseline = top + row_height - 15
            bb:paintRect(origin_x + 7, baseline, width - 14, shelf_thickness, BB.COLOR_GRAY_4)
            bb:paintRect(origin_x + 7, baseline, width - 14, 2, BB.COLOR_BLACK)
            paintShelfEdgeHighlight(bb, origin_x + 7, baseline + shelf_thickness, width - 14, shelf_3d_level)
            if shelf_shadow > 0 then
                local shadow_y = baseline + shelf_thickness
                blendRect(bb, origin_x + 7, shadow_y, width - 14, shelf_shadow, shelf_core)
                for band = 1, shelf_soft do
                    local ci = math.min(#shelf_feather, math.max(1, math.ceil(band * #shelf_feather / shelf_soft)))
                    blendRect(bb, origin_x + 8, shadow_y + shelf_shadow + band - 1, width - 16, 1, shelf_feather[ci])
                end
            end
        end
    end

    if owner.tab == "home" then
        -- HOME contains hundreds of small architectural strokes and text
        -- widgets.  Keep the fully composed content bitmap between tab
        -- switches; a return to HOME then becomes one blit instead of a full
        -- reconstruction of the station scene.
        local slots = owner:homeBoardSlots()
        local slot_key = table.concat({tostring(slots[1] or "-"),tostring(slots[2] or "-"),tostring(slots[3] or "-"),tostring(slots[4] or "-")}, ",")
        local cache_key = table.concat({
            tostring(width), tostring(height), os.date("%Y%m%d%H%M"),
            tostring(owner._home_render_generation or 0), slot_key,
        }, "|")
        local cached = owner._home_render_cache
        if not cached or cached.key ~= cache_key then
            if cached and cached.bb and cached.bb.free then pcall(cached.bb.free, cached.bb) end
            local home_bb = BB.new(math.max(1,width), math.max(1,height), bb:getType())
            home_bb:fill(BB.COLOR_WHITE)
            owner:paintHomeV4(home_bb, 0, 0, width, height)
            cached = {key=cache_key, bb=home_bb}
            owner._home_render_cache = cached
        end
        bb:blitFrom(cached.bb, origin_x, origin_y, 0, 0, width, height)
        owner:paintNavbar(bb, origin_x, origin_y + height, width)
        return
    end
    if owner.tab == "stats" then
        owner:paintReadingLine(bb, origin_x, origin_y, width, height)
        owner:paintNavbar(bb, origin_x, origin_y + height, width)
        return
    end

    if owner.tab == "showcase" then
        owner:paintShowcase(bb, origin_x, origin_y, width, height)
        owner:paintNavbar(bb, origin_x, origin_y + height, width)
        return
    end

    local page = owner.pages[owner.page] or {}
    -- The bookshelf is a spine crop, not a front-cover card. Never reuse the
    -- showcase's stretched full-cover path here.
    for _, placement in ipairs(page) do
        local book, style = placement.book, placement.style
        local x = origin_x + placement.x
        local y = origin_y + placement.y
        local w, h = placement.w, placement.h
        paintSoftShadow(bb, x, y, w, h, book_shadow, book_soft, book_core, book_feather)
        bb:paintRoundedRect(x, y, w, h, BB.COLOR_GRAY_4, style.corner)
        if style.corner > 0 then
            bb:paintRect(x, y + style.corner, w, math.max(1, h - style.corner), BB.COLOR_GRAY_4)
        end

        local cover = customSpineWidget(style.custom_spine, math.max(1, w - 4), math.max(1, h - 2), style.spine_fit)
        if not cover then
            cover = getBookSpineWidget(book.path,
                math.max(1, w - 4), math.max(1, h - 2), style.crop_align)
        end
        if cover then
            paintTopRoundedWidget(cover, bb, x + 2, y + 2, math.max(1, w - 4), math.max(1, h - 2), math.max(0, style.corner - 2))
            if cover.free then cover:free() end
        end
        paintBookEdgeHighlight(bb, x, y, w, h, book_3d_level, style.corner)

        if style.show_title ~= false then
        local letters = utf8Chars(book.title)
        local font_size = style.font_size or 15
        local line_step = math.max(3, style.line_spacing or 20)
        local column_step = font_size + 2
        local lines = math.max(1, math.floor((h - 12) / line_step))
        local columns = math.max(1, math.floor((w - 8) / column_step))
        local visible_count = math.min(#letters, lines * columns)
        local used_columns = math.max(1, math.ceil(visible_count / lines))
        local block_width = used_columns * column_step
        local block_left = x + math.floor((w - block_width) / 2)
        local longest_column = math.min(lines, visible_count)
        local block_height = (longest_column - 1) * line_step + font_size
        local block_top = y + math.floor((h - block_height) / 2)
        if style.title_vpos == "top" then block_top = y + 6
        elseif style.title_vpos == "upper" then block_top = y + math.floor((h - block_height) / 4)
        elseif style.title_vpos == "lower" then block_top = y + math.floor((h - block_height) * 3 / 4)
        elseif style.title_vpos == "bottom" then block_top = y + h - block_height - 6 end
        local index = 1
        local color = TEXT_COLORS[style.text_color] or BB.COLOR_WHITE
        for column = 1, used_columns do
            for line = 1, lines do
                if not letters[index] then break end
                local tx = block_left + (used_columns - column) * column_step
                local ty = block_top + (line - 1) * line_step
                drawText(bb, letters[index], tx, ty, font_size, true, nil, color)
                index = index + 1
            end
        end
        end
        owner.hit_books[#owner.hit_books + 1] = { x=x, y=y, w=w, h=h, book=book }
    end
    owner:paintNavbar(bb, origin_x, origin_y + height, width)
end

Shelf = InputContainer:extend{ name = "simplebookshelf_window", covers_fullscreen = true }

function Shelf:buildPages()
    self.pages = {}
    local screen_width = Screen:getWidth()
    local content_height = self.content_height
    local rows = math.max(1, math.min(5, globalSetting("shelf_rows") or 3))
    local row_height = math.floor(content_height / rows)
    local side_margin_pct = { .006, .015, .035, .07, .12 }
    local top_margin_pct = { .04, .08, .14, .23, .34 }
    local left_level = math.max(1, math.min(5, globalSetting("book_left_margin_level") or 2))
    local right_level = math.max(1, math.min(5, globalSetting("book_right_margin_level") or 2))
    local top_level = math.max(1, math.min(5, globalSetting("book_top_margin_level") or 3))
    local left_margin = math.floor(screen_width * side_margin_pct[left_level])
    local right_margin = math.floor(screen_width * side_margin_pct[right_level])
    local top_margin = math.floor(row_height * top_margin_pct[top_level])
    local gap = 3
    local page, row, cursor = {}, 1, left_margin
    for _, book in ipairs(self.books) do
        local style = bookStyle(book.path, self.standalone)
        local scale = (globalSetting("book_scale") or 100) / 100
        local override = book_overrides[book.path]
        local base_width = type(override) == "table" and override.width
            or defaultSpineWidthForPages(book.pages)
        style.width = base_width
        local w = math.max(42, math.min(165, math.floor(base_width * scale)))
        if cursor + w > screen_width - right_margin then row, cursor = row + 1, left_margin end
        if row > rows then
            self.pages[#self.pages + 1] = page
            page, row, cursor = {}, 1, left_margin
        end
        local h = math.floor((row_height - top_margin) * math.max(55, math.min(100, style.height_pct)) / 100 * scale)
        h = math.max(20, math.min(row_height - 18, h))
        local baseline = row * row_height - 15
        page[#page + 1] = { book=book, style=style, x=cursor, y=baseline-h, w=w, h=h }
        cursor = cursor + w + gap
    end
    self.pages[#self.pages + 1] = page
    if #self.pages == 0 then self.pages = { {} } end
    self.page_num = #self.pages
    self.page = math.max(1, math.min(self.page or 1, self.page_num))
end

function Shelf:init()
    local GestureRange = require("ui/gesturerange")
    self.sui_plugin = nil
    local has_simpleui = false
    self.content_height = math.max(120, Screen:getHeight() - NAVBAR_HEIGHT)
    self.tab = self.tab or "bookshelf"
    if not navigationTabEnabled(self.tab) then self.tab = enabledNavigationTabs()[1] end
    self.stats_view = self.stats_view or "day"
    if not statsOptionEnabled(self.stats_view) then self.stats_view = enabledStatsViews()[1] end
    self.stats_date = self.stats_date or os.time()
    -- KOReader only emits double_tap when the foreground widget explicitly
    -- enables it. Keep single-tap mode immediate; enable the short double-tap
    -- waiting window only when the user selected that opening mode.
    self.disable_double_tap = globalSetting("book_open_mode") ~= "double"
    self.page = 1
    self.scan_root = libraryRoot()
    self.books = cachedBooks(self.scan_root)
    sortBooks(self.books)
    self:buildPages()

    self.canvas = ShelfCanvas:new{ width=Screen:getWidth(), height=Screen:getHeight(), owner=self }
    self.canvas.dimen = Geom:new{ w=Screen:getWidth(), h=Screen:getHeight() }
    self[1] = self.canvas
    self.dimen = Geom:new{ x=0, y=0, w=Screen:getWidth(), h=Screen:getHeight() }

    local native_top_h = math.floor(Screen:getHeight() * .12)
    local content_range = function()
        return Geom:new{ x=0, y=native_top_h, w=Screen:getWidth(), h=math.max(1, self.content_height - native_top_h) }
    end
    local nav_range = function()
        return Geom:new{ x=0, y=self.content_height, w=Screen:getWidth(), h=NAVBAR_HEIGHT }
    end
    -- Keep the top-of-screen swipe available to KOReader/SimpleUI.  The
    -- shelf itself only needs page swipes from the content area; registering
    -- a full-screen swipe here would win over SimpleUI's menu gesture.
    local swipe_range = function()
        local top = native_top_h
        if has_simpleui then
            pcall(function()
                local Topbar = require("sui_topbar")
                if Topbar and Topbar.TOTAL_TOP_H then
                    top = tonumber(Topbar.TOTAL_TOP_H()) or 0
                end
            end)
        end
        return Geom:new{
            x = 0,
            y = top,
            w = Screen:getWidth(),
            h = math.max(1, Screen:getHeight() - top),
        }
    end

    -- A shelf page is not FileManagerMenu, so SimpleUI's normal top-menu
    -- zones are not installed automatically. Install the same swipe/tap
    -- entry point here and resolve the live menu at gesture time.
    if self.registerTouchZones then
        -- This plugin can run without SimpleUI.  In that case the native
        -- reader menu still exists behind the overlay as ReaderUI.instance.menu.
        -- Forward only the top pull-down/tap zone; never consume it as a page
        -- swipe, so KOReader's normal menu remains available.
        local top_menu_ratio = 0.12
        local function liveMenu()
            local ReaderUI = package.loaded["apps/reader/readerui"]
            local reader = ReaderUI and ReaderUI.instance
            if reader and reader.menu then return reader.menu end
            local plugin = self.sui_plugin
            local fm = plugin and plugin.ui
            if fm and fm.menu then return fm.menu end
            local FM = package.loaded["apps/filemanager/filemanager"]
            local inst = FM and FM.instance
            return inst and inst.menu or nil
        end
        self:registerTouchZones({
            {
                id = "simplebookshelf_menu_tap",
                ges = "tap",
                screen_zone = { ratio_x=0, ratio_y=0, ratio_w=1, ratio_h=top_menu_ratio },
                handler = function(ges)
                    local menu = liveMenu()
                    if menu and menu.onTapShowMenu then
                        return menu:onTapShowMenu(ges)
                    end
                    return false
                end,
            },
            {
                id = "simplebookshelf_menu_swipe",
                ges = "swipe",
                screen_zone = { ratio_x=0, ratio_y=0, ratio_w=1, ratio_h=top_menu_ratio },
                handler = function(ges)
                    local menu = liveMenu()
                    if menu and menu.onSwipeShowMenu then
                        return menu:onSwipeShowMenu(ges)
                    end
                    return false
                end,
            },
        })
    end
    self.ges_events = {
        TapNav = { GestureRange:new{ ges="tap", range=nav_range } },
        HoldNav = { GestureRange:new{ ges="hold", range=nav_range } },
        TapBook = { GestureRange:new{ ges="tap", range=content_range } },
        DoubleTapBook = { GestureRange:new{ ges="double_tap", range=content_range } },
        HoldBook = { GestureRange:new{ ges="hold", range=content_range } },
        SwipePage = { GestureRange:new{ ges="swipe", range=swipe_range } },
    }

    -- Let the cached page reach the e-ink screen before touching storage.
    UIManager:scheduleIn(.25, function()
        if Shelf.instance == self then
            self:refreshBooks(false)
            UIManager:setDirty(self, "full")
        end
    end)
end

-- Showcase has its own horizontal pages.  It must not inherit the spine
-- bookshelf's page packing: changing cover size here only changes how many
-- covers fit on a cabinet page.
function Shelf:buildShowcasePages()
    local pages, page = {}, {}
    local width, height = Screen:getWidth(), self.content_height
    local rows = math.max(2, math.min(6, tonumber(showcaseSetting("rows")) or 5))
    local scale = math.max(70, math.min(180, tonumber(showcaseSetting("book_scale")) or 100)) / 100
    local gap = math.max(2, tonumber(showcaseSetting("book_gap")) or 10)
    local margin_left = math.max(8, tonumber(showcaseSetting("margin_left")) or 48)
    local margin_right = math.max(8, tonumber(showcaseSetting("margin_right")) or 48)
    local row_h = math.floor(height / rows)
    local filter = self:getShowcaseFilter()
    local row, cursor = 1, margin_left
    for _, book in ipairs(self.books or {}) do
        if self:showcaseBookMatches(book, filter) then
            local book_w, book_h = showcaseBookDimensions(book, row_h, scale)
            local lean, depth = showcaseBookProjection(book_h)
            local projected_w = book_w + lean + depth
            if cursor + projected_w > width - margin_right then row, cursor = row + 1, margin_left end
            if row > rows then
                pages[#pages + 1] = page
                page, row, cursor = {}, 1, margin_left
            end
            page[#page + 1] = book
            cursor = cursor + projected_w + gap
        end
    end
    if #page > 0 or #pages == 0 then pages[#pages + 1] = page end
    self.showcase_pages = pages
    self.page_num = #pages
    self.page = math.max(1, math.min(self.page or 1, self.page_num))
end

local function homeScale(width, height)
    return math.max(.42, math.min(1.25, math.min(width / 1200, height / 1600)))
end

function Shelf:paintHome(bb, x, y, width, height)
    local s = homeScale(width, height)
    local function X(v) return x + math.floor(v * s) end
    local function Y(v) return y + math.floor(v * s) end
    local function W(v) return math.floor(v * s) end
    local ink, paper, soft = BB.COLOR_BLACK, BB.COLOR_WHITE, BB.COLOR_GRAY_E
    bb:paintRect(x, y, width, height, paper)
    -- The page is intentionally built from ratios and a scale factor: no
    -- device-specific pixel geometry is used here.
    bb:paintRect(X(0), Y(0), width, W(116), BB.COLOR_GRAY_4)
    bb:paintRect(X(46), Y(0), width - W(92), W(116), paper)
    bb:paintRect(X(46), Y(112), width - W(92), W(3), ink)
    drawCenteredText(bb, "HOME STATION", x, Y(62), W(58), true, width, ink)
    drawCenteredText(bb, "阅读主页", x, Y(101), W(25), true, width, ink)
    self.home_title_hit = {x=x, y=Y(55), w=width, h=W(60)}

    local ticket_y, ticket_h = 132, 122
    bb:paintRect(X(74), Y(ticket_y), width - W(148), W(ticket_h), soft)
    bb:paintRect(X(74), Y(ticket_y), width - W(148), 2, ink)
    bb:paintRect(X(74), Y(ticket_y + ticket_h - 2), width - W(148), 2, ink)
    local today = os.date("%m.%d")
    drawText(bb, "TODAY", X(108), Y(ticket_y + 22), W(18), false, nil, ink)
    drawText(bb, today, X(108), Y(ticket_y + 52), W(34), true, nil, ink)
    drawText(bb, "阅读，是一场抵达内心的旅行。", X(380), Y(ticket_y + 44), W(18), false, nil, ink)
    drawText(bb, "TICKET NO.", X(780), Y(ticket_y + 22), W(18), false, nil, ink)
    drawText(bb, os.date("%Y%m%d") .. "-" .. tostring(os.date("%j")):sub(-2), X(780), Y(ticket_y + 52), W(27), true, nil, ink)
    local battery_x = X(1010)
    bb:paintRect(battery_x, Y(ticket_y + 35), W(28), W(15), ink)
    bb:paintRect(battery_x + W(3), Y(ticket_y + 38), W(22), W(9), paper)
    drawText(bb, "83%", X(1048), Y(ticket_y + 34), W(22), true, nil, ink)

    local books = self.books or {}
    local current = books[1]
    for _, book in ipairs(books) do
        if book.percent and book.percent > 0 and book.percent < .995 then current = book; break end
    end
    local board_y = 280
    bb:paintRect(X(74), Y(board_y), width - W(148), W(350), soft)
    bb:paintRect(X(74), Y(board_y), width - W(148), 2, ink)
    drawText(bb, "正在阅读", X(100), Y(board_y + 32), W(23), true, nil, ink)
    drawText(bb, "· CURRENT READING", X(250), Y(board_y + 32), W(14), false, nil, ink)
    self.home_notes_hit = {x=X(74), y=Y(board_y + 20), w=width-W(148), h=W(44)}
    if current then
        local cover = getBookCoverWidget(current.path, W(165), W(230), "center")
        if cover then cover:paintTo(bb, X(105), Y(board_y + 65)); if cover.free then cover:free() end end
        drawText(bb, current.title or "未命名书籍", X(305), Y(board_y + 105), W(35), true, nil, ink)
        drawText(bb, current.authors or "", X(305), Y(board_y + 140), W(18), false, nil, ink)
        local pct = math.floor((tonumber(current.percent) or 0) * 100)
        drawText(bb, "当前进度", X(305), Y(board_y + 232), W(17), false, nil, ink)
        drawText(bb, tostring(pct) .. "%", X(705), Y(board_y + 225), W(33), true, nil, ink)
        bb:paintRect(X(305), Y(board_y + 250), W(420), W(7), ink)
        bb:paintRect(X(305), Y(board_y + 250), math.floor(W(420) * pct / 100), W(7), BB.COLOR_GRAY_8)
        drawText(bb, "继续阅读", X(855), Y(board_y + 130), W(24), true, nil, ink)
        drawText(bb, "▶", X(900), Y(board_y + 190), W(30), true, nil, ink)
    else
        drawText(bb, "暂无正在阅读的书籍", X(305), Y(board_y + 130), W(24), false, nil, ink)
    end

    local recent_y = 650
    bb:paintRect(X(74), Y(recent_y), width - W(148), W(270), soft)
    drawText(bb, "最近停靠", X(100), Y(recent_y + 32), W(23), true, nil, ink)
    drawText(bb, "· RECENT STOPS", X(250), Y(recent_y + 32), W(14), false, nil, ink)
    self.home_hit_books = {}
    local shown = math.min(5, #books)
    for i = 1, shown do
        local book = books[i]
        local card_x = 100 + (i - 1) * 205
        bb:paintRect(X(card_x), Y(recent_y + 58), W(175), W(175), paper)
        bb:paintRect(X(card_x), Y(recent_y + 58), W(175), 2, ink)
        local cover = getBookCoverWidget(book.path, W(145), W(120), "center")
        if cover then cover:paintTo(bb, X(card_x + 15), Y(recent_y + 72)); if cover.free then cover:free() end end
        drawCenteredText(bb, book.title, X(card_x), Y(recent_y + 204), W(14), true, W(175), ink)
        self.home_hit_books[#self.home_hit_books + 1] = {x=X(card_x), y=Y(recent_y + 58), w=W(175), h=W(175), book=book}
    end
    local line_y = 1010
    drawText(bb, "本周线路", X(100), Y(line_y), W(23), true, nil, ink)
    drawText(bb, "· WEEKLY LINE", X(250), Y(line_y), W(14), false, nil, ink)
    bb:paintRect(X(110), Y(line_y + 70), width - W(220), W(3), ink)
    for i = 1, 7 do
        local px = X(130 + (i - 1) * 155)
        bb:paintCircle(px, Y(line_y + 71), W(12), i > 4 and BB.COLOR_BLACK or paper)
        bb:paintCircle(px, Y(line_y + 71), W(9), i > 4 and BB.COLOR_BLACK or paper)
        drawCenteredText(bb, ({"MON","TUE","WED","THU","FRI","SAT","SUN"})[i], px - W(30), Y(line_y + 92), W(13), true, W(60), ink)
    end
    self.hit_books = self.home_hit_books
end

function Shelf:paintHomeV2(bb, x, y, width, height)
    local ref_w, ref_h = 1006, 1093
    local sx, sy = (width - 24) / ref_w, (height - 12) / ref_h
    local ox, oy = x + 12, y + 6
    local font_s = math.min(1, sx, sy)
    local function X(v) return math.floor(ox + v * sx) end
    local function Y(v) return math.floor(oy + v * sy) end
    local function RW(v) return math.max(1, math.floor(v * sx)) end
    local function RH(v) return math.max(1, math.floor(v * sy)) end
    local function F(v) return math.max(6, math.floor(v * font_s)) end
    local function R(px, py, pw, ph, color) bb:paintRect(X(px), Y(py), RW(pw), RH(ph), color) end
    local function H(px, py, pw, thick, color) R(px, py, pw, thick or 1, color or BB.COLOR_BLACK) end
    local function V(px, py, ph, thick, color) R(px, py, thick or 1, ph, color or BB.COLOR_BLACK) end
    local function T(text, px, py, size, bold, maxw, color) drawText(bb, tostring(text or ""), X(px), Y(py), F(size), bold, maxw and RW(maxw) or nil, color or BB.COLOR_BLACK) end
    local function CT(text, px, py, pw, size, bold, color) drawCenteredText(bb, tostring(text or ""), X(px), Y(py), F(size), bold, RW(pw), color or BB.COLOR_BLACK) end
    local function C(cx, cy, radius, color)
        local rr = math.max(2, math.floor(radius * math.min(sx, sy)))
        if bb.paintCircle then pcall(bb.paintCircle, bb, X(cx), Y(cy), rr, color) else R(cx-radius, cy-radius, radius*2, radius*2, color) end
    end
    local ink, paper, pale, mid = BB.COLOR_BLACK, BB.COLOR_WHITE, BB.COLOR_GRAY_E, BB.COLOR_GRAY_8
    R(0, 0, ref_w, ref_h, paper)
    -- Station entrance: masonry, layered beam, iron arch and clock.
    R(0, 0, 72, ref_h, BB.COLOR_GRAY_3); R(ref_w-72, 0, 72, ref_h, BB.COLOR_GRAY_3)
    for side = 0, 1 do local px = side == 0 and 12 or ref_w - 66; for groove = 0, 4 do R(px + groove*11, 0, 5, ref_h, groove % 2 == 0 and BB.COLOR_GRAY_6 or BB.COLOR_GRAY_2) end end
    R(72, 0, ref_w-144, 218, pale); H(72, 30, ref_w-144, 16, ink); H(72, 49, ref_w-144, 5, BB.COLOR_GRAY_6)
    local arch_mid = ref_w / 2
    for step = 0, 34 do local px = 76 + step * ((ref_w - 152) / 34); local dx = (px - arch_mid) / (arch_mid - 76); local py = 42 + math.floor(dx * dx * 72); R(px, py, 28, 8, ink) end
    for _, px in ipairs({86, 110, 890, 914}) do R(px, 52, 13, 155, BB.COLOR_GRAY_2); R(px+4, 52, 5, 155, BB.COLOR_GRAY_7) end
    R(78, 28, 92, 82, BB.COLOR_GRAY_2); R(ref_w-170, 28, 92, 82, BB.COLOR_GRAY_2)
    CT("PLATFORM", 78, 44, 92, 11, false, paper); CT("01", 78, 66, 92, 28, true, paper)
    CT("PLATFORM", ref_w-170, 44, 92, 11, false, paper); CT("01", ref_w-170, 66, 92, 28, true, paper)
    C(arch_mid, 72, 60, ink); C(arch_mid, 72, 51, paper); C(arch_mid, 72, 47, ink); C(arch_mid, 72, 44, paper)
    H(arch_mid-2, 52, 4, 22, ink); H(arch_mid, 72, 31, 3, ink); C(arch_mid, 72, 5, ink); C(arch_mid, 72, 2, paper)
    CT("HOME STATION", 150, 126, ref_w-300, 35, true, ink); H(166, 176, 220, 1, mid); H(620, 176, 220, 1, mid); CT("阅读主页", 386, 166, 234, 20, true, ink)
    self.home_title_hit = {x=X(150), y=Y(122), w=RW(ref_w-300), h=RH(70)}
    -- Day ticket.
    local ty = 220
    R(72, ty, ref_w-144, 92, pale); H(72, ty, ref_w-144, 1, ink); H(72, ty+91, ref_w-144, 1, ink); V(270, ty, 92, 1, mid); V(662, ty, 92, 1, mid)
    T("TODAY", 102, ty+18, 11, false); T(os.date("%m.%d"), 102, ty+42, 28, false); T("已阅读", 102, ty+72, 11, false, nil, mid)
    T("DESTINATION", 316, ty+24, 11, false); T("阅读，是一场抵达内心的旅行。", 316, ty+49, 15, false, 310)
    T("TICKET NO.", 692, ty+17, 11, false); T(os.date("%Y%m%d") .. "-" .. tostring(os.date("%j")):sub(-2), 692, ty+39, 21, false)
    local battery = 0; pcall(function() battery = tonumber(Device:getPowerDevice():getCapacity()) or 0 end)
    R(890, ty+24, 24, 13, ink); R(893, ty+27, 18, 7, paper); T(tostring(battery) .. "%", 923, ty+20, 16, true)
    for bar = 0, 34 do if bar % 3 ~= 1 then R(692 + bar*5, ty+72, bar % 5 == 0 and 3 or 1, 15, ink) end end
    local books = self.books or {}; local current = books[1]
    for _, book in ipairs(books) do if tonumber(book.percent) and book.percent > 0 and book.percent < .995 then current = book; break end end
    local cy = 326
    R(72, cy, ref_w-144, 300, pale); H(86, cy+32, ref_w-172, 1, mid); T("正在阅读", 94, cy+12, 17, true); T("· CURRENT READING", 210, cy+15, 10, false)
    self.home_hit_books = {}
    if current then
        local cover = getBookCoverWidget(current.path, RW(145), RH(170), "center"); if cover then cover:paintTo(bb, X(100), Y(cy+52)); if cover.free then cover:free() end end
        T(current.title or "未命名书籍", 270, cy+72, 27, true, 430); T(current.authors or "", 270, cy+112, 13, false, 420)
        local pct = math.max(0, math.min(100, math.floor((tonumber(current.percent) or 0)*100)))
        T("当前进度", 270, cy+172, 12, false); T(tostring(pct).."%", 678, cy+160, 26, true); R(270, cy+197, 430, 6, ink); R(270, cy+197, math.floor(430*pct/100), 6, BB.COLOR_GRAY_7)
        V(735, cy+45, 182, 1, mid); CT("CONTINUE", 758, cy+84, 140, 13, false); CT("继续阅读", 758, cy+108, 140, 15, true); CT("▶", 758, cy+144, 140, 24, true)
        self.home_hit_books[1] = {x=X(100), y=Y(cy+52), w=RW(800), h=RH(170), book=current}
    end
    H(86, cy+238, ref_w-172, 1, mid)
    local metrics = {{"已读时长","动态"},{"预计剩余","动态"},{"阅读次数","动态"},{"总页数","动态"}}
    for i, item in ipairs(metrics) do local mx=96+(i-1)*220; if i>1 then V(mx-14,cy+246,42,1,mid) end; T(item[1],mx,cy+250,10,false); T(item[2],mx,cy+269,15,true) end
    local ry = 642
    R(72, ry, ref_w-144, 210, pale); H(86, ry+32, ref_w-172, 1, mid); T("最近停靠",94,ry+12,17,true); T("· RECENT STOPS",210,ry+15,10,false)
    for i=1,math.min(5,#books) do
        local book=books[i]; local bx=96+(i-1)*176; R(bx,ry+48,152,140,paper); H(bx,ry+48,152,1,ink)
        local cover=getBookCoverWidget(book.path,RW(122),RH(82),"center"); if cover then cover:paintTo(bb,X(bx+15),Y(ry+58)); if cover.free then cover:free() end end
        CT(book.title or "",bx+5,ry+148,142,11,true); local pct=math.floor((tonumber(book.percent) or 0)*100); T(tostring(pct).."%",bx+15,ry+172,10,true)
        C(bx+36,ry+191,8,ink); C(bx+116,ry+191,8,ink); H(bx-5,ry+192,162,2,ink)
        self.home_hit_books[#self.home_hit_books+1]={x=X(bx),y=Y(ry+48),w=RW(152),h=RH(140),book=book}
    end
    local wy=870
    R(72,wy,ref_w-144,108,pale); T("本周线路",94,wy+12,17,true); T("· WEEKLY LINE",210,wy+15,10,false); H(120,wy+62,ref_w-240,2,ink)
    for i=1,7 do local px=132+(i-1)*123; C(px,wy+63,9,ink); C(px,wy+63,5,i>=5 and ink or paper); CT(({"MON","TUE","WED","THU","FRI","SAT","SUN"})[i],px-35,wy+78,70,10,true) end
    local my=992
    R(72,my,ref_w-144,86,pale); T("本月月台",94,my+10,17,true); T("· MONTH PLATFORM",210,my+13,10,false)
    for i=1,31 do local col=(i-1)%16; local row=math.floor((i-1)/16); local bx=94+col*52; local by=my+38+row*24; CT(tostring(i),bx,by-10,18,7,false); R(bx,by,18,18,(i%5==0 or i%7==0) and BB.COLOR_GRAY_7 or paper) end
    self.hit_books = self.home_hit_books
end

local function homeDuration(seconds)
    seconds = math.max(0, tonumber(seconds) or 0)
    local hours, minutes = math.floor(seconds / 3600), math.floor((seconds % 3600) / 60)
    if hours > 0 then return string.format("%dh %02dm", hours, minutes) end
    return string.format("%d min", minutes)
end

local function homeShortText(value, limit)
    local chars = utf8Chars(tostring(value or ""))
    if #chars <= limit then return table.concat(chars) end
    local result = {}
    for i = 1, math.max(1, limit - 1) do result[#result + 1] = chars[i] end
    return table.concat(result) .. "…"
end

function Shelf:homeStatisticsSnapshot(current)
    local now = os.time()
    local key = tostring(current and current.title or "")
    local cached = self.home_statistics_cache
    if cached and cached.key == key and now - cached.at < 45 then return cached.value end
    local value = {pages=0, total_seconds=0, visits=0, authors="", week={}, month={}, today_seconds=0}
    local today = os.date("*t", now)
    local midnight = os.time{year=today.year, month=today.month, day=today.day, hour=0, min=0, sec=0}
    local monday = midnight - ((today.wday + 5) % 7) * 86400
    local month_start = os.time{year=today.year, month=today.month, day=1, hour=0, min=0, sec=0}
    local month_end = os.time{year=today.year, month=today.month + 1, day=1, hour=0, min=0, sec=0}
    local rows = self:readingRows(math.min(monday, month_start), month_end)
    for _, row in ipairs(rows or {}) do
        local seconds = math.max(0, tonumber(row.duration) or 0)
        local row_day = os.date("*t", row.time)
        if row.time >= monday and row.time < monday + 7 * 86400 then
            local slot = math.floor((row.time - monday) / 86400) + 1
            value.week[slot] = (value.week[slot] or 0) + seconds
        end
        if row.time >= month_start and row.time < month_end then
            value.month[row_day.day] = (value.month[row_day.day] or 0) + seconds
        end
        if row.time >= midnight and row.time < midnight + 86400 then value.today_seconds = value.today_seconds + seconds end
    end
    if current then
        local ok, err = pcall(function()
            local SQ3 = require("lua-ljsqlite3/init")
            local conn = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
            local stmt = conn:prepare([[SELECT id, pages, total_read_time, total_read_pages, authors
                FROM book WHERE title = ? ORDER BY total_read_time DESC LIMIT 1;]])
            local row = stmt:reset():bind(tostring(current.title or "")):step()
            if row then
                local book_id = tonumber(row[1])
                value.pages = tonumber(row[2]) or 0
                value.total_seconds = tonumber(row[3]) or 0
                value.read_pages = tonumber(row[4]) or 0
                value.authors = tostring(row[5] or "")
                if book_id then
                    local visits = conn:prepare([[SELECT start_time, duration FROM page_stat_data
                        WHERE id_book = ? ORDER BY start_time ASC;]])
                    local visit_row = visits:reset():bind(book_id):step()
                    local previous_end
                    while visit_row do
                        local started = tonumber(visit_row[1]) or 0
                        local finished = started + math.max(0, tonumber(visit_row[2]) or 0)
                        if not previous_end or started - previous_end > 20 * 60 then
                            value.visits = value.visits + 1
                        end
                        previous_end = math.max(previous_end or 0, finished)
                        visit_row = visits:step()
                    end
                    visits:close()
                end
            end
            stmt:close(); conn:close()
        end)
        if not ok then logger.warn("simplebookshelf: home statistics failed", err) end
    end
    self.home_statistics_cache = {key=key, at=now, value=value}
    return value
end

function Shelf:homeCurrentBook(books)
    local now = os.time()
    local cached = self.home_current_cache
    local latest_title
    if cached and now - cached.at < 45 then
        latest_title = cached.title
    else
        pcall(function()
            local SQ3 = require("lua-ljsqlite3/init")
            local conn = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
            latest_title = conn:rowexec([[SELECT b.title FROM page_stat_data p
                JOIN book b ON b.id = p.id_book
                WHERE b.total_read_time > 0
                ORDER BY p.start_time DESC LIMIT 1;]])
            conn:close()
        end)
        self.home_current_cache = {at=now, title=latest_title}
    end
    if latest_title then
        for _, book in ipairs(books or {}) do
            if tostring(book.title or "") == tostring(latest_title) then return book end
        end
    end
    local current, newest = nil, -1
    for _, book in ipairs(books or {}) do
        local pct = tonumber(book.percent) or 0
        if pct >= .01 and pct < .995 and (tonumber(book.last_read) or 0) >= newest then
            current, newest = book, tonumber(book.last_read) or 0
        end
    end
    return current or (books and books[1])
end

function Shelf:paintHomeV3(bb, x, y, width, height)
    local ref_w, ref_h = 1006, 1093
    local sx, sy = (width - 20) / ref_w, (height - 10) / ref_h
    local ox, oy = x + 10, y + 5
    local font_s = math.min(1, sx, sy)
    local function X(v) return math.floor(ox + v * sx) end
    local function Y(v) return math.floor(oy + v * sy) end
    local function RW(v) return math.max(1, math.floor(v * sx)) end
    local function RH(v) return math.max(1, math.floor(v * sy)) end
    local function F(v) return math.max(6, math.floor(v * font_s)) end
    local function R(px, py, pw, ph, color) bb:paintRect(X(px), Y(py), RW(pw), RH(ph), color) end
    local function H(px, py, pw, thick, color) R(px, py, pw, thick or 1, color or BB.COLOR_BLACK) end
    local function V(px, py, ph, thick, color) R(px, py, thick or 1, ph, color or BB.COLOR_BLACK) end
    local function T(text, px, py, size, bold, maxw, color) drawText(bb, tostring(text or ""), X(px), Y(py), F(size), bold, maxw and RW(maxw) or nil, color or BB.COLOR_BLACK) end
    local function CT(text, px, py, pw, size, bold, color) drawCenteredText(bb, tostring(text or ""), X(px), Y(py), F(size), bold, RW(pw), color or BB.COLOR_BLACK) end
    local function C(cx, cy, radius, color)
        local rr = math.max(2, math.floor(radius * math.min(sx, sy)))
        if bb.paintCircle then pcall(bb.paintCircle, bb, X(cx), Y(cy), rr, color) else R(cx-radius, cy-radius, radius*2, radius*2, color) end
    end
    local function L(x1, y1, x2, y2, thick, color)
        local steps = math.max(1, math.floor(math.max(math.abs(x2-x1), math.abs(y2-y1)) / 2))
        for i = 0, steps do local q=i/steps; R(x1+(x2-x1)*q, y1+(y2-y1)*q, thick or 1.5, thick or 1.5, color or BB.COLOR_BLACK) end
    end
    local function dashedRect(px, py, pw, ph, color)
        for n=0,math.floor(pw/12) do if n%2==0 then H(px+n*12,py,10,1,color); H(px+n*12,py+ph,10,1,color) end end
        for n=0,math.floor(ph/12) do if n%2==0 then V(px,py+n*12,10,1,color); V(px+pw,py+n*12,10,1,color) end end
    end
    local function barcode(px, py, pw, ph)
        local cursor, n = px, 1
        while cursor < px + pw do
            local bar = (n % 7 == 0 and 4) or (n % 3 == 0 and 2) or 1
            R(cursor, py, bar, ph, BB.COLOR_BLACK); cursor = cursor + bar + (n % 4 == 0 and 3 or 2); n = n + 1
        end
    end
    local ink, paper, pale, mid, dark = BB.COLOR_BLACK, BB.COLOR_WHITE, BB.COLOR_GRAY_E, BB.COLOR_GRAY_8, BB.COLOR_GRAY_3
    R(0, 0, ref_w, ref_h, paper)

    local books = self.books or {}
    local current
    local recent = {}
    for _, book in ipairs(books) do
        recent[#recent + 1] = book
    end
    table.sort(recent, function(a,b) return (tonumber(a.last_read) or 0) > (tonumber(b.last_read) or 0) end)
    current = self:homeCurrentBook(books)
    local stats = self:homeStatisticsSnapshot(current)

    -- Deep side pillars and a smoother layered station arch.
    R(0,0,72,ref_h,dark); R(ref_w-72,0,72,ref_h,dark)
    for side=0,1 do local px=side==0 and 8 or ref_w-67; for groove=0,5 do R(px+groove*10,0,5,ref_h,groove%2==0 and BB.COLOR_GRAY_6 or BB.COLOR_GRAY_2) end end
    R(72,0,ref_w-144,220,pale); H(72,24,ref_w-144,13,ink); H(72,40,ref_w-144,4,BB.COLOR_GRAY_6)
    local mid_x=ref_w/2
    for px=74,932,3 do
        local q=(px-mid_x)/(mid_x-74); local ay=35+q*q*78
        R(px,ay,4,7,ink); R(px,ay+10,4,4,BB.COLOR_GRAY_7)
    end
    for _,px in ipairs({82,108,896,922}) do R(px,51,12,158,BB.COLOR_GRAY_2); R(px+4,51,4,158,BB.COLOR_GRAY_7) end
    H(74,202,136,7,ink); H(796,202,136,7,ink)
    R(76,25,94,86,BB.COLOR_GRAY_2); R(ref_w-170,25,94,86,BB.COLOR_GRAY_2)
    CT("PLATFORM",76,42,94,10,false,paper); CT("01",76,65,94,27,true,paper)
    CT("PLATFORM",ref_w-170,42,94,10,false,paper); CT("01",ref_w-170,65,94,27,true,paper)
    R(76,126,48,54,BB.COLOR_GRAY_2); R(ref_w-124,126,48,54,BB.COLOR_GRAY_2)
    CT("ENTRY",76,136,48,8,false,paper); CT("→",76,153,48,18,true,paper)
    CT("TO READ",ref_w-124,136,48,7,false,paper); CT("→",ref_w-124,153,48,18,true,paper)

    C(mid_x,69,62,ink); C(mid_x,69,55,paper); C(mid_x,69,51,ink); C(mid_x,69,48,paper)
    local romans={"XII","I","II","III","IV","V","VI","VII","VIII","IX","X","XI"}
    for i,label in ipairs(romans) do local a=(i-1)*math.pi/6-math.pi/2; CT(label,mid_x+math.cos(a)*34-12,69+math.sin(a)*34-5,24,7,true) end
    L(mid_x,69,mid_x-2,44,2.2,ink); L(mid_x,69,mid_x+27,63,2.2,ink); C(mid_x,69,5,ink); C(mid_x,69,2,paper)
    CT("HOME STATION",153,124,ref_w-306,31,true,ink); H(164,177,225,1,mid); H(617,177,225,1,mid); CT("阅读主页",395,166,216,18,true,ink)
    self.home_title_hit={x=X(145),y=Y(118),w=RW(ref_w-290),h=RH(76)}

    -- Ticket strip; its battery and barcode share the same right edge.
    local ty=220
    R(72,ty,ref_w-144,92,pale); H(72,ty,ref_w-144,1,ink); H(72,ty+91,ref_w-144,1,ink); V(278,ty,92,1,mid); V(670,ty,92,1,mid)
    C(72,ty+46,7,paper); C(ref_w-72,ty+46,7,paper)
    T("TODAY",102,ty+17,10,false); T(os.date("%m.%d"),102,ty+39,26,false); T("已阅读 "..homeDuration(stats.today_seconds),102,ty+70,10,false,nil,mid)
    T("DESTINATION",314,ty+22,10,false); T("阅读，是一场抵达内心的旅行。",314,ty+47,13,false,330)
    T("TICKET NO.",694,ty+14,10,false); T(os.date("%m%Y").."-"..os.date("%d"),694,ty+35,19,false); barcode(694,ty+69,232,15)
    local battery=0; pcall(function() battery=tonumber(Device:getPowerDevice():getCapacity()) or 0 end)
    R(852,ty+22,24,13,ink); R(855,ty+25,18,7,paper); R(876,ty+26,3,5,ink); T(tostring(battery).."%",884,ty+18,14,true,42)

    -- Current-reading ticket.
    local cy=326
    R(72,cy,ref_w-144,300,pale); H(86,cy+32,ref_w-172,1,mid); drawPluginIcon(bb,"13-railway-station.svg",X(94),Y(cy+7),RW(16)); T("正在阅读",118,cy+10,15,true); T("· CURRENT READING",264,cy+14,9,false)
    self.home_hit_books={}
    if current then
        local cover=getBookCoverWidget(current.path,RW(145),RH(170),"center"); if cover then cover:paintTo(bb,X(100),Y(cy+52)); if cover.free then cover:free() end end
        local authors=tostring(current.authors or ""); if authors=="" then authors=stats.authors end
        T(homeShortText(current.title or "未命名书籍",18),270,cy+66,25,true,430); T(authors,270,cy+106,11,false,420)
        local pct=math.max(0,math.min(100,math.floor((tonumber(current.percent) or 0)*100+.5)))
        local pages=stats.pages>0 and stats.pages or math.max(0,math.floor((stats.read_pages or 0)/math.max(.01,pct/100)))
        local current_page=pages>0 and math.floor(pages*pct/100+.5) or 0
        T("当前进度",270,cy+164,10,false); T(tostring(pct).."%",650,cy+151,24,true,50)
        R(270,cy+190,430,7,paper); H(270,cy+190,430,1,ink); H(270,cy+196,430,1,ink); if pct>0 then R(270,cy+191,430*pct/100,5,ink) end
        if pages>0 then T(tostring(current_page).." / "..tostring(pages).." 页",615,cy+202,9,false,85,mid) end
        V(735,cy+44,184,1,mid); dashedRect(758,cy+62,140,84,mid); CT("CONTINUE",758,cy+76,140,11,false); CT("继续阅读",758,cy+97,140,13,true); CT("▶",758,cy+118,140,20,true); barcode(758,cy+176,140,16)
        self.home_hit_books[1]={x=X(100),y=Y(cy+52),w=RW(800),h=RH(170),book=current}
        H(86,cy+238,ref_w-172,1,mid)
        local remaining=(pct>0 and pct<100) and stats.total_seconds*(100-pct)/pct or 0
        local metrics={{"已读时长",homeDuration(stats.total_seconds)},{"预计剩余",homeDuration(remaining)},{"阅读次数",tostring(stats.visits)},{"总页数",pages>0 and tostring(pages) or "—"}}
        for i,item in ipairs(metrics) do local mx=96+(i-1)*220; if i>1 then V(mx-14,cy+246,42,1,mid) end; T(item[1],mx,cy+248,9,false); T(item[2],mx,cy+267,14,true) end
    end

    -- Recent stops as coupled ticket carriages with one title line and visible wheel sets.
    local ry=642
    R(72,ry,ref_w-144,210,pale); H(86,ry+32,ref_w-172,1,mid); drawPluginIcon(bb,"13-railway-station.svg",X(94),Y(ry+7),RW(16)); T("最近停靠",118,ry+10,15,true); T("· RECENT STOPS",264,ry+14,9,false); T("查看更多 →",842,ry+12,10,false,88)
    for i=1,math.min(5,#recent) do
        local book=recent[i]; local bx=96+(i-1)*176; R(bx,ry+47,152,134,paper)
        H(bx,ry+47,152,1,ink); H(bx,ry+180,152,1,ink); V(bx,ry+47,134,1,mid); V(bx+151,ry+47,134,1,mid)
        C(bx,ry+67,5,pale); C(bx+152,ry+67,5,pale)
        local cover=getBookCoverWidget(book.path,RW(122),RH(58),"center"); if cover then cover:paintTo(bb,X(bx+15),Y(ry+58)); if cover.free then cover:free() end end
        CT(homeShortText(book.title or "",8),bx+8,ry+122,136,9,true)
        local pct=math.max(0,math.floor((tonumber(book.percent) or 0)*100+.5)); T(tostring(pct).."%",bx+14,ry+145,8,true); H(bx+51,ry+153,72,2,mid); if pct>0 then H(bx+51,ry+153,72*pct/100,2,ink) end
        if tonumber(book.last_read) and book.last_read>0 then CT("停靠 "..os.date("%m.%d",book.last_read),bx+20,ry+163,112,7,false,mid) end
        C(bx+34,ry+190,9,ink); C(bx+34,ry+190,4,paper); C(bx+118,ry+190,9,ink); C(bx+118,ry+190,4,paper); H(bx-6,ry+190,164,2,ink)
        if i<5 then H(bx+152,ry+175,24,2,ink) end
        self.home_hit_books[#self.home_hit_books+1]={x=X(bx),y=Y(ry+47),w=RW(152),h=RH(145),book=book}
    end
    H(86,ry+199,ref_w-172,2,ink); H(86,ry+204,ref_w-172,1,mid)

    -- Reading-variation sparkline above the weekly station line.
    local wy=860
    R(72,wy,ref_w-144,125,pale); drawPluginIcon(bb,"13-railway-station.svg",X(94),Y(wy+7),RW(16)); T("本周线路",118,wy+10,15,true); T("· WEEKLY LINE",264,wy+14,9,false)
    local week_total,max_week=0,1; for i=1,7 do week_total=week_total+(stats.week[i] or 0); max_week=math.max(max_week,stats.week[i] or 0) end
    T("本周时长 "..homeDuration(week_total).." →",805,wy+12,10,false,130)
    local points={}; for i=1,7 do points[i]={x=132+(i-1)*123,y=wy+57-28*(stats.week[i] or 0)/max_week}; if (stats.week[i] or 0)>0 then V(points[i].x,points[i].y,wy+62-points[i].y,1,BB.COLOR_GRAY_C) end; C(points[i].x,points[i].y,3,ink); if i>1 then L(points[i-1].x,points[i-1].y,points[i].x,points[i].y,1.8,BB.COLOR_GRAY_4) end end
    H(120,wy+62,ref_w-240,1,BB.COLOR_GRAY_C)
    H(120,wy+83,ref_w-240,1,ink)
    for i=1,7 do local px=132+(i-1)*123; C(px,wy+83,9,ink); C(px,wy+83,5,(stats.week[i] or 0)>0 and ink or paper); CT(({"MON","TUE","WED","THU","FRI","SAT","SUN"})[i],px-35,wy+96,70,8,true); CT(homeDuration(stats.week[i] or 0),px-40,wy+108,80,7,false,mid) end

    local my=992
    R(72,my,ref_w-144,86,pale); drawPluginIcon(bb,"13-railway-station.svg",X(94),Y(my+5),RW(16)); T("本月月台",118,my+8,15,true); T("· MONTH PLATFORM",264,my+12,9,false)
    local read_days=0; for day=1,31 do if (stats.month[day] or 0)>0 then read_days=read_days+1 end end
    T("阅读天数 "..tostring(read_days).." →",836,my+10,9,false,98)
    for day=1,31 do local col=(day-1)%21; local row=math.floor((day-1)/21); local bx=96+col*39; local by=my+39+row*27; CT(tostring(day),bx-3,by-11,24,6,false); R(bx,by,17,17,(stats.month[day] or 0)>0 and ((stats.month[day] or 0)>1800 and ink or BB.COLOR_GRAY_7) or paper); H(bx,by,17,1,mid); H(bx,by+16,17,1,mid); V(bx,by,17,1,mid); V(bx+16,by,17,1,mid) end
    self.hit_books=self.home_hit_books
end

local HOME_BOARD_OPTIONS = {
    {key="current", label="正在阅读"},
    {key="recent", label="最近停靠"},
    {key="week", label="本周线路"},
    {key="month", label="本月月台"},
    {key="quote", label="阅读签"},
    {key="random", label="随机发车"},
    {key="notes", label="票根笔记"},
}

local function homeBoardEnabled(key)
    local value = store:readSetting("home_board_" .. key)
    return value == nil and (key == "current" or key == "recent" or key == "week" or key == "month") or value == true
end

function Shelf:homeBoardSlots()
    local enabled = {}
    for _, option in ipairs(HOME_BOARD_OPTIONS) do if homeBoardEnabled(option.key) then enabled[option.key] = true end end
    local slots = {
        enabled.current and "current" or nil,
        enabled.recent and "recent" or nil,
        enabled.week and "week" or nil,
        enabled.month and "month" or nil,
    }
    local preferred = {random=1, notes=2, quote=3}
    for _, key in ipairs({"random", "notes", "quote"}) do
        if enabled[key] then
            local target = preferred[key]
            if slots[target] then
                local empty
                for i=1,4 do if not slots[i] then empty=i; break end end
                target=empty or target
            end
            slots[target]=key
        end
    end
    return slots
end

function Shelf:homeNotesSnapshot()
    local now=os.time(); local cached=self.home_notes_cache
    if cached and now-cached.at<90 then return cached.items end
    local ordered={}; for _,book in ipairs(self.books or {}) do ordered[#ordered+1]=book end
    table.sort(ordered,function(a,b) return (tonumber(a.last_read) or 0)>(tonumber(b.last_read) or 0) end)
    local notes={}
    for _,book in ipairs(ordered) do
        for _,note in ipairs(bookHighlights(book.path)) do
            notes[#notes+1]={text=note.text,page=note.page,book=book}
            if #notes>=80 then break end
        end
        if #notes>=80 then break end
    end
    self.home_notes_cache={at=now,items=notes}; return notes
end

function Shelf:showAllHomeNotes()
    local Menu=require("ui/widget/menu"); local menu; local items={}; local self_owner=self
    for _,entry in ipairs(self:homeNotesSnapshot()) do
        local saved=entry
        items[#items+1]={
            text=homeShortText(saved.text,34).."\n《"..tostring(saved.book.title or "").."》 "..tostring(saved.book.authors or ""),
            _home_note_entry=saved,
            callback=function() UIManager:close(menu); openBookThroughFileManager(self,saved.book.path) end,
        }
    end
    if #items==0 then items[1]={text="尚未找到划线或笔记",enabled_func=function() return false end} end
    menu=Menu:new{title="票根笔记",item_table=items,width=math.floor(Screen:getWidth()*.82),height=math.floor(Screen:getHeight()*.72),items_font_size=PLUGIN_MENU_FONT_SIZE,items_mandatory_font_size=PLUGIN_MENU_FONT_SIZE}
    function menu:onMenuHold(item)
        if item and item._home_note_entry then
            UIManager:close(self)
            self_owner:confirmDeleteHomeHighlight(item._home_note_entry)
        end
        return true
    end
    standardizePluginMenu(menu); UIManager:show(menu)
end

function Shelf:confirmDeleteHomeHighlight(entry)
    if not entry or not entry.book or not entry.book.path then return end
    local ConfirmBox=require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text="删除这条划线？\n\n"..homeShortText(entry.text,54).."\n\n《"..tostring(entry.book.title or "").."》",
        ok_text="删除划线",
        ok_callback=function()
            local ok,err=pcall(function()
                local DocSettings=require("docsettings")
                local settings=DocSettings:open(entry.book.path)
                for _,key in ipairs({"bookmarks","annotations"}) do
                    local raw=settings:readSetting(key)
                    if type(raw)=="table" then
                        local cleaned,removed={},false
                        for _,item in ipairs(raw) do
                            local text=type(item)=="table" and (item.text or item.note or item.highlight or item.title) or nil
                            local page=type(item)=="table" and (item.page or item.pageno or item.page_number) or nil
                            local same_page=entry.page==nil or page==nil or tostring(page)==tostring(entry.page)
                            if not removed and text and tostring(text)==tostring(entry.text) and same_page then removed=true else cleaned[#cleaned+1]=item end
                        end
                        if removed then settings:saveSetting(key,cleaned) end
                    end
                end
                if settings.flush then settings:flush() end
                if settings.close then settings:close() end
            end)
            if not ok then logger.warn("simplebookshelf: delete home highlight failed",err) end
            self.home_notes_cache=nil
            self:invalidateHomeRenderCache()
            UIManager:setDirty(self,"full")
        end,
    })
end

-- Exact native projection of the approved 1040 x 1141 station composition.
-- Every major boundary below follows the reference image instead of being
-- independently stretched for a particular Kindle resolution.
function Shelf:paintHomeV4(bb, x, y, width, height)
    local ref_w, ref_h = 1040, 1141
    local sx, sy = (width - 20) / ref_w, (height - 10) / ref_h
    local ox, oy = x + 10, y + 5
    -- On compact portrait panels (KPW6 class), the reference's capped 1x
    -- fonts are physically too small even though the layout has spare scaled
    -- width. Raise text independently from geometry; larger devices preserve
    -- the approved typography exactly.
    local compact_home = width <= 1300 and height <= 1650
    local font_s = compact_home and math.min(1.10, sx, sy) or math.min(1, sx, sy)
    local function X(v) return math.floor(ox + v * sx) end
    local function Y(v) return math.floor(oy + v * sy) end
    local function W(v) return math.max(1, math.floor(v * sx)) end
    local function Ht(v) return math.max(1, math.floor(v * sy)) end
    local function F(v)
        local size = math.floor(v * font_s)
        -- Tiny bilingual captions and dates need one additional pixel to stay
        -- legible on the smaller 300-dpi panel.
        if compact_home and v <= 9 then size = size + 1 end
        return math.max(6, size)
    end
    local function R(px,py,pw,ph,c) bb:paintRect(X(px),Y(py),W(pw),Ht(ph),c) end
    local function HR(px,py,pw,t,c) R(px,py,pw,t or 1,c or BB.COLOR_BLACK) end
    local function VR(px,py,ph,t,c) R(px,py,t or 1,ph,c or BB.COLOR_BLACK) end
    local function T(s,px,py,size,bold,maxw,c) drawText(bb,tostring(s or ""),X(px),Y(py),F(size),bold,maxw and W(maxw) or nil,c or BB.COLOR_BLACK) end
    local function CT(s,px,py,pw,size,bold,c) drawCenteredTextMeasured(bb,tostring(s or ""),X(px),Y(py),F(size),bold,W(pw),c or BB.COLOR_BLACK) end
    local function RT(s,right,py,pw,size,bold,c) drawRightAlignedTextMeasured(bb,tostring(s or ""),X(right),Y(py),F(size),bold,W(pw),c or BB.COLOR_BLACK) end
    local function C(cx,cy,r,c)
        local rr=math.max(2,math.floor(r*math.min(sx,sy)))
        if bb.paintCircle then pcall(bb.paintCircle,bb,X(cx),Y(cy),rr,c) else R(cx-r,cy-r,r*2,r*2,c) end
    end
    local function L(x1,y1,x2,y2,t,c)
        local steps=math.max(1,math.floor(math.max(math.abs(x2-x1),math.abs(y2-y1))/2))
        for i=0,steps do local q=i/steps; R(x1+(x2-x1)*q,y1+(y2-y1)*q,t or 1.4,t or 1.4,c or BB.COLOR_BLACK) end
    end
    local function barcode(px,py,pw,ph)
        local at,n=px,1
        while at<px+pw do local bw=(n%7==0 and 4) or (n%3==0 and 2) or 1; R(at,py,bw,ph,BB.COLOR_BLACK); at=at+bw+(n%4==0 and 3 or 2); n=n+1 end
    end
    local function dashed(px,py,pw,ph,c)
        for n=0,math.floor(pw/10) do if n%2==0 then HR(px+n*10,py,8,1,c); HR(px+n*10,py+ph,8,1,c) end end
        for n=0,math.floor(ph/10) do if n%2==0 then VR(px,py+n*10,8,1,c); VR(px+pw,py+n*10,8,1,c) end end
    end
    local function calendarIcon(px,py)
        R(px,py+3,21,19,BB.COLOR_WHITE); HR(px,py+3,21,1,BB.COLOR_BLACK); HR(px,py+9,21,1,BB.COLOR_BLACK); HR(px,py+21,21,1,BB.COLOR_BLACK); VR(px,py+3,19,1,BB.COLOR_BLACK); VR(px+20,py+3,19,1,BB.COLOR_BLACK); VR(px+5,py,6,2,BB.COLOR_BLACK); VR(px+15,py,6,2,BB.COLOR_BLACK)
    end
    local function metricIcon(kind,px,py)
        if kind==1 then C(px+9,py+9,8,BB.COLOR_BLACK); C(px+9,py+9,5,BB.COLOR_WHITE); L(px+9,py+9,px+9,py+3,1,BB.COLOR_BLACK); L(px+9,py+9,px+14,py+12,1,BB.COLOR_BLACK)
        elseif kind==2 then HR(px+2,py,15,2,BB.COLOR_BLACK); HR(px+2,py+18,15,2,BB.COLOR_BLACK); L(px+4,py+2,px+15,py+17,1.5,BB.COLOR_BLACK); L(px+15,py+2,px+4,py+17,1.5,BB.COLOR_BLACK)
        elseif kind==3 then calendarIcon(px,py)
        else VR(px+2,py+2,18,2,BB.COLOR_BLACK); VR(px+16,py+2,18,2,BB.COLOR_BLACK); HR(px+4,py+3,12,1,BB.COLOR_BLACK); HR(px+4,py+19,12,1,BB.COLOR_BLACK); VR(px+9,py+2,18,1,BB.COLOR_GRAY_8) end
    end
    local ink,paper,pale,mid,dark=BB.COLOR_BLACK,BB.COLOR_WHITE,BB.COLOR_GRAY_E,BB.COLOR_GRAY_8,BB.COLOR_GRAY_3
    R(0,0,ref_w,ref_h,paper)

    local books=self.books or {}; local recent={}
    for _,book in ipairs(books) do recent[#recent+1]=book end
    table.sort(recent,function(a,b) return (tonumber(a.last_read) or 0)>(tonumber(b.last_read) or 0) end)
    local current=self:homeCurrentBook(books); local stats=self:homeStatisticsSnapshot(current); local board_slots=self:homeBoardSlots()
    self.home_action_hits={}; self.home_hold_action_hits={}

    -- Header: deep fluted sides, filled iron arch, hanging clock and signs.
    -- The outer masonry is decorative, not part of the 80..970 content grid.
    -- Keep the composition fixed while slimming both full-height columns to
    -- roughly two thirds of their previous visual width.
    R(0,0,54,ref_h,dark); R(993,0,47,ref_h,dark)
    for groove=0,4 do R(5+groove*10,0,5,ref_h,groove%2==0 and BB.COLOR_GRAY_6 or BB.COLOR_GRAY_2) end
    for groove=0,4 do R(995+groove*9,0,4,ref_h,groove%2==0 and BB.COLOR_GRAY_6 or BB.COLOR_GRAY_2) end
    for course=1,7 do HR(0,course*32,54,1,BB.COLOR_GRAY_6); HR(993,course*32,47,1,BB.COLOR_GRAY_6) end
    R(80,0,890,253,pale); HR(80,8,890,11,ink)
    local center=520
    for px=80,970,3 do local q=(px-center)/440; local outer=18+q*q*82; local inner=39+q*q*67; R(px,outer,4,math.max(4,inner-outer),ink); R(px,inner+3,4,4,BB.COLOR_GRAY_7) end
    for px=150,890,72 do local q=(px-center)/440; local ay=18+q*q*82; L(px,0,px+24,ay,2,ink); C(px+24,ay,3,ink) end
    for _,px in ipairs({96,125,886,915}) do R(px-5,66,23,8,ink); R(px,74,13,166,BB.COLOR_GRAY_2); R(px+4,74,5,166,BB.COLOR_GRAY_7); R(px-6,230,25,8,ink) end
    local function romanCornerColumn(cx)
        R(cx-20,88,40,5,ink); R(cx-16,93,32,5,BB.COLOR_GRAY_4); R(cx-12,98,24,7,ink)
        C(cx-15,98,6,ink); C(cx+15,98,6,ink); C(cx-15,98,3,pale); C(cx+15,98,3,pale)
        R(cx-10,105,20,119,BB.COLOR_GRAY_4); R(cx-7,105,3,119,BB.COLOR_GRAY_8); R(cx-1,105,3,119,BB.COLOR_GRAY_8); R(cx+5,105,3,119,BB.COLOR_GRAY_8)
        R(cx-13,224,26,6,ink); R(cx-18,230,36,6,BB.COLOR_GRAY_4); R(cx-22,236,44,7,ink)
    end
    romanCornerColumn(160); romanCornerColumn(948)
    HR(80,238,143,8,ink); HR(817,238,153,8,ink)
    VR(43,0,24,3,ink); VR(115,0,24,3,ink); VR(925,0,24,3,ink); VR(997,0,24,3,ink)
    R(13,19,132,131,ink); R(18,24,122,121,BB.COLOR_GRAY_2); R(895,19,132,131,ink); R(900,24,122,121,BB.COLOR_GRAY_2)
    HR(23,30,112,1,BB.COLOR_GRAY_8); HR(905,30,112,1,BB.COLOR_GRAY_8); HR(23,139,112,1,BB.COLOR_GRAY_8); HR(905,139,112,1,BB.COLOR_GRAY_8)
    for _,dot in ipairs({{25,31},{133,31},{25,137},{133,137},{907,31},{1015,31},{907,137},{1015,137}}) do C(dot[1],dot[2],2,paper) end
    CT("PLATFORM",18,48,122,10,false,paper); CT("01",18,79,122,30,true,paper); CT("PLATFORM",900,48,122,10,false,paper); CT("01",900,79,122,30,true,paper)
    VR(53,145,8,2,ink); VR(91,145,8,2,ink); VR(949,145,8,2,ink); VR(987,145,8,2,ink)
    R(29,146,86,82,ink); R(34,151,76,72,BB.COLOR_GRAY_2); R(925,146,86,82,ink); R(930,151,76,72,BB.COLOR_GRAY_2)
    HR(39,157,66,1,BB.COLOR_GRAY_8); HR(935,157,66,1,BB.COLOR_GRAY_8); CT("ENTRY",34,166,76,8,false,paper); CT("→",34,187,76,20,true,paper); CT("TO READ",930,166,76,7,false,paper); CT("→",930,187,76,20,true,paper)
    C(center,91,78,ink); C(center,91,69,paper); C(center,91,63,ink); C(center,91,59,paper)
    local romans={"XII","I","II","III","IV","V","VI","VII","VIII","IX","X","XI"}
    for i,label in ipairs(romans) do local a=(i-1)*math.pi/6-math.pi/2; CT(label,center+math.cos(a)*44-13,91+math.sin(a)*44-5,26,7,true) end
    local clock=os.date("*t"); local minute=(clock.min or 0)+(clock.sec or 0)/60; local hour=((clock.hour or 0)%12)+minute/60
    local minute_angle=minute*math.pi/30-math.pi/2; local hour_angle=hour*math.pi/6-math.pi/2
    L(center,91,center+math.cos(hour_angle)*31,91+math.sin(hour_angle)*31,2.4,ink)
    L(center,91,center+math.cos(minute_angle)*43,91+math.sin(minute_angle)*43,1.8,ink)
    C(center,91,6,ink); C(center,91,2,paper)
    CT("HOME STATION",270,158,500,29,true,ink); HR(165,215,286,1,mid); HR(589,215,286,1,mid); CT("阅读主页",452,205,136,13,true,ink)
    self.home_title_hit={x=X(260),y=Y(148),w=W(520),h=Ht(82)}

    -- Header ticket, matching the reference's 80/280/679/970 grid.
    local ty=253
    R(80,ty,890,99,pale); HR(80,ty,890,1,ink); HR(80,ty+98,890,1,ink); VR(280,ty,99,1,mid); VR(679,ty,99,1,mid); C(80,ty+50,7,paper); C(970,ty+50,7,paper)
    calendarIcon(109,ty+39); T("TODAY",140,ty+18,8,false); T(os.date("%m.%d"),140,ty+44,18,false); T("已阅读 "..homeDuration(stats.today_seconds),140,ty+72,8,false,nil,mid)
    drawPluginIcon(bb,"03-train-front.svg",X(302),Y(ty+37),W(22)); T("DESTINATION",340,ty+20,8,false); T("阅读，是一场抵达内心的旅行。",340,ty+49,9,false,300)
    T("TICKET NO.",696,ty+17,8,false); T(os.date("%m%Y").."-"..os.date("%d"),696,ty+41,15,false); barcode(696,ty+70,186,15)
    local battery=0; pcall(function() battery=tonumber(Device:getPowerDevice():getCapacity()) or 0 end); R(894,ty+25,22,12,ink); R(897,ty+28,16,6,paper); R(916,ty+29,3,4,ink); T(tostring(battery).."%",924,ty+22,11,true,36)

    local function twoLines(value,limit)
        local chars=utf8Chars(tostring(value or "")); local first,second={},{}
        for i,ch in ipairs(chars) do if i<=limit then first[#first+1]=ch elseif i<=limit*2 then second[#second+1]=ch end end
        if #chars>limit*2 then second[#second+1]="…" end
        return table.concat(first),table.concat(second)
    end
    local function addAction(px,py,pw,ph,callback)
        self.home_action_hits[#self.home_action_hits+1]={x=X(px),y=Y(py),w=W(pw),h=Ht(ph),callback=callback}
    end
    local function addHoldAction(px,py,pw,ph,callback)
        self.home_hold_action_hits[#self.home_hold_action_hits+1]={x=X(px),y=Y(py),w=W(pw),h=Ht(ph),callback=callback}
    end
    local function renderCustomPanel(key,py,ph)
        R(80,py,890,ph,pale)
        if not key then return end
        local labels={quote="READING NOTE",random="随机发车",notes="票根笔记"}; local english={quote="",random="RANDOM DEPARTURE",notes="TICKET NOTES"}
        drawPluginIcon(bb,"03-train-front.svg",X(94),Y(py+6),W(22)); T(labels[key] or key,124,py+10,12,true); if english[key] and english[key]~="" then T("· "..english[key],222,py+13,8,false) end; HR(94,py+31,862,1,mid)
        if key=="random" then
            if #recent==0 then CT("书库中还没有可发车的书",180,py+math.floor(ph*.48),680,12,false,mid); return end
            local index=(math.floor(os.time()/3600)%#recent)+1; local book=recent[index]
            local cover_h=math.max(58,math.min(150,ph-72)); local cover_w=math.floor(cover_h*.72)
            local random_w,random_h=W(cover_w),Ht(cover_h)
            local cover=getBookCoverWidget(book.path,random_w,random_h,"center",true)
            if cover then cover:paintTo(bb,X(108),Y(py+43)); if cover.free then cover:free() end
            else queueHomeCoverLoad(self,book.path,random_w,random_h,"center",Geom:new{x=X(108),y=Y(py+43),w=random_w,h=random_h}) end
            T(homeShortText(book.title or "",18),145+cover_w,py+58,20,true,560)
            local author=tostring(book.authors or ""); if author=="" then author="作者信息未记录" end
            T(homeShortText(author,32),145+cover_w,py+94,10,false,540)
            local pct=math.floor((tonumber(book.percent) or 0)*100+.5)
            local depart_y=py+61
            RT("随机发车  ▶",938,depart_y,270,13,true)
            addAction(668,depart_y-5,270,34,function() openBookThroughFileManager(self,book.path) end)
            RT("当前停靠 "..tostring(pct).."%",938,py+math.min(ph-39,132),270,10,false)
            self.home_hit_books[#self.home_hit_books+1]={x=X(96),y=Y(py+38),w=W(850),h=Ht(ph-45),book=book}
        elseif key=="notes" then
            local notes=self:homeNotesSnapshot(); local entry=#notes>0 and notes[(math.floor(os.time()/60)%#notes)+1] or nil
            if entry then
                local one,two=twoLines("“"..entry.text.."”",30); T(one,122,py+55,14,true,790); if two~="" then T(two,122,py+82,14,true,790) end
                T("《"..tostring(entry.book.title or "").."》  "..tostring(entry.book.authors or ""),122,py+math.min(ph-35,118),9,false,760,mid)
            else
                CT("尚未找到划线或笔记",180,py+math.floor(ph*.5),680,12,false,mid)
            end
            T("查看全部笔记 →",816,py+10,9,false,140); addAction(94,py+4,862,30,function() self:showAllHomeNotes() end)
        elseif key=="quote" then
            local quotes={
                {"A reader lives a thousand lives before he dies.","George R. R. Martin"},
                {"Books are a uniquely portable magic.","Stephen King"},
                {"There is no frigate like a book to take us lands away.","Emily Dickinson"},
                {"Reading is a conversation with the finest minds of past centuries.","René Descartes"},
                {"Once you learn to read, you will be forever free.","Frederick Douglass"},
                {"Reading brings us unknown friends.","Honoré de Balzac"},
                {"A book is a dream that you hold in your hand.","Neil Gaiman"},
                {"The reading of all good books is like conversation with the finest minds.","René Descartes"},
            }
            local selected=quotes[(math.floor(os.time()/60)%#quotes)+1]
            local line_limit=ph<145 and 42 or 48
            local one,two=twoLines("“"..selected[1].."”",line_limit)
            local quote_size=ph<145 and 11 or 14
            local first_y=py+(two~="" and 47 or math.max(50,math.floor(ph*.46)))
            CT(one,116,first_y,808,quote_size,true)
            if two~="" then CT(two,116,first_y+math.max(20,quote_size+9),808,quote_size,true) end
            CT("— "..selected[2],250,py+math.min(ph-27,118),540,9,false,mid)
        end
    end

    -- Current reading: 365-630, with the exact reference columns.
    local cy=365
    self.home_hit_books={}
    if board_slots[1]=="current" then
        R(80,cy,890,265,pale); drawPluginIcon(bb,"03-train-front.svg",X(94),Y(cy+6),W(22)); T("正在阅读",124,cy+11,10,true); T("· CURRENT READING",212,cy+14,7,false); HR(94,cy+31,862,1,mid)
      if current then
        local current_w,current_h=W(141),Ht(151)
        local cover=getBookCoverWidget(current.path,current_w,current_h,"center",true)
        if cover then cover:paintTo(bb,X(92),Y(cy+43)); if cover.free then cover:free() end
        else queueHomeCoverLoad(self,current.path,current_w,current_h,"center",Geom:new{x=X(92),y=Y(cy+43),w=current_w,h=current_h}) end
        local authors=tostring(current.authors or ""); if authors=="" then authors=stats.authors end
        T(homeShortText(current.title or "未命名书籍",18),252,cy+55,18,true,455); T(authors,252,cy+94,9,false,440)
        local pct=math.max(0,math.min(100,math.floor((tonumber(current.percent) or 0)*100+.5))); local pages=stats.pages>0 and stats.pages or 0; local current_page=pages>0 and math.floor(pages*pct/100+.5) or 0
        T("当前进度",252,cy+150,8,false); T(tostring(pct).."%",742,cy+141,18,true,47); HR(252,cy+169,536,1,ink); HR(252,cy+176,536,1,ink); if pct>0 then R(252,cy+170,536*pct/100,6,ink) end; if pages>0 then T(tostring(current_page).." / "..tostring(pages).." 页",699,cy+185,7,false,89,mid) end
        VR(810,cy+43,151,1,mid); dashed(825,cy+53,132,90,mid); CT("CONTINUE",825,cy+65,132,8,false); CT("继续阅读",825,cy+85,132,9,true); CT("▶",825,cy+103,132,17,true); barcode(825,cy+161,132,16)
        addAction(825,cy+51,132,98,function() openBookThroughFileManager(self,current.path) end)
        self.home_hit_books[1]={x=X(92),y=Y(cy+43),w=W(865),h=Ht(151),book=current}
        HR(94,cy+202,862,1,mid)
        local remaining=(pct>0 and pct<100) and stats.total_seconds*(100-pct)/pct or 0
        local metrics={{"已读时长",homeDuration(stats.total_seconds),"READING TIME"},{"预计剩余",homeDuration(remaining),"LEFT TIME"},{"阅读次数",tostring(stats.visits),"VISITS"},{"总页数",pages>0 and tostring(pages) or "—","PAGES"}}
        for i,item in ipairs(metrics) do local mx=103+(i-1)*219; if i>1 then VR(mx-15,cy+211,42,1,mid) end; metricIcon(i,mx,cy+218); T(item[2],mx+29,cy+216,11,true,130); T(item[3].." · "..item[1],mx+29,cy+236,7,false,150,mid) end
      end
    else
        renderCustomPanel(board_slots[1],cy,265)
    end

    -- Recent stops: five equal 158-wide ticket carriages on the same rail.
    local ry=635
    if board_slots[2]=="recent" then
      R(80,ry,890,199,pale); drawPluginIcon(bb,"03-train-front.svg",X(94),Y(ry+6),W(22)); T("最近停靠",124,ry+11,10,true); T("· RECENT STOPS",212,ry+14,7,false); T("查看更多 →",888,ry+12,8,false,68); HR(94,ry+31,862,1,mid)
      for i=1,math.min(5,#recent) do
        local book=recent[i]; local bx=111+(i-1)*168; R(bx+4,ry+53,158,110,BB.COLOR_GRAY_C); R(bx,ry+48,158,110,paper); HR(bx,ry+48,158,1,ink); HR(bx,ry+157,158,1,ink); VR(bx,ry+48,110,1,mid); VR(bx+157,ry+48,110,1,mid); C(bx,ry+68,5,pale); C(bx+158,ry+68,5,pale)
        local crop_w,crop_h=W(141),Ht(50)
        local cover=getBookSpineWidget(book.path,crop_w,crop_h,"center",true)
        if cover then
            cover:paintTo(bb,X(bx+8),Y(ry+57)); if cover.free then cover:free() end
        else
            queueHomeCropLoad(self,book.path,crop_w,crop_h,"center",Geom:new{x=X(bx+8),y=Y(ry+57),w=crop_w,h=crop_h})
        end
        CT(homeShortText(book.title or "",8),bx+9,ry+111,140,8,true); local pct=math.max(0,math.floor((tonumber(book.percent) or 0)*100+.5)); T(tostring(pct).."%",bx+13,ry+133,7,true); HR(bx+48,ry+140,72,2,mid); if pct>0 then HR(bx+48,ry+140,72*pct/100,2,ink) end; if tonumber(book.last_read) and book.last_read>0 then CT("停靠 "..os.date("%m.%d",book.last_read),bx+23,ry+143,112,6,false,mid) end
        C(bx+29,ry+166,8,ink); C(bx+29,ry+166,3,paper); C(bx+129,ry+166,8,ink); C(bx+129,ry+166,3,paper); if i<5 then HR(bx+158,ry+155,10,2,ink) end
        self.home_hit_books[#self.home_hit_books+1]={x=X(bx),y=Y(ry+48),w=W(158),h=Ht(126),book=book}
      end
      HR(103,ry+166,850,2,ink); HR(103,ry+173,850,1,mid)
    else
      renderCustomPanel(board_slots[2],ry,199)
    end

    -- Weekly chart: filled variation graph above a separate station timeline.
    local wy=840
    if board_slots[3]=="week" then
      R(80,wy,890,157,pale); drawPluginIcon(bb,"03-train-front.svg",X(94),Y(wy+6),W(22)); T("本周线路",124,wy+11,10,true); T("· WEEKLY LINE",212,wy+14,7,false)
    local total,maxv=0,1; for i=1,7 do total=total+(stats.week[i] or 0); maxv=math.max(maxv,stats.week[i] or 0) end; T("本周时长 "..homeDuration(total).." →",851,wy+11,9,false,105)
    local pts={}; for i=1,7 do pts[i]={x=104+(i-1)*140,y=wy+83-31*(stats.week[i] or 0)/maxv} end
    for i=2,7 do local a,b=pts[i-1],pts[i]; for px=a.x,b.x,2 do local q=(px-a.x)/(b.x-a.x); local py=a.y+(b.y-a.y)*q; R(px,py,2,wy+86-py,BB.COLOR_GRAY_C) end; L(a.x,a.y,b.x,b.y,1.4,BB.COLOR_GRAY_4) end
    HR(103,wy+86,854,1,mid); for i=1,7 do C(pts[i].x,pts[i].y,3,paper) end
    HR(132,wy+120,784,1,ink)
    for i=1,7 do local px=159+(i-1)*122; CT(({"MON","TUE","WED","THU","FRI","SAT","SUN"})[i],px-34,wy+96,68,8,true); C(px,wy+120,8,ink); C(px,wy+120,4,(stats.week[i] or 0)>0 and ink or paper); CT(homeDuration(stats.week[i] or 0),px-38,wy+132,76,7,false,mid) end
    else renderCustomPanel(board_slots[3],wy,157) end

    -- Month platform: the reference's 21 + 10 compact square cells.
    local my=1002
    if board_slots[4]=="month" then
      R(80,my,890,139,pale); drawPluginIcon(bb,"03-train-front.svg",X(94),Y(my+5),W(22)); T("本月月台",124,my+10,10,true); T("· MONTH PLATFORM",212,my+13,7,false)
    local read_days=0; for d=1,31 do if (stats.month[d] or 0)>0 then read_days=read_days+1 end end; T("阅读天数 "..tostring(read_days).." →",870,my+10,9,false,86)
    for day=1,31 do local col=(day-1)%21; local row=math.floor((day-1)/21); local bx=103+col*40; local by=my+54+row*41; CT(tostring(day),bx-2,by-14,23,6,false); local fill=(stats.month[day] or 0)>0 and ((stats.month[day] or 0)>1800 and ink or BB.COLOR_GRAY_7) or paper; R(bx,by,19,19,fill); HR(bx,by,19,1,mid); HR(bx,by+18,19,1,mid); VR(bx,by,19,1,mid); VR(bx+18,by,19,1,mid) end
    else renderCustomPanel(board_slots[4],my,139) end
    self.hit_books=self.home_hit_books
end

function Shelf:paintNavbar(bb, x, y, width)
    local icons = { "ko-home.svg", "ko-bookcase.svg", "ko-statistics.svg", "ko-display-shelf.svg" }
    local tabs = enabledNavigationTabs()
    local active = 1
    for i, tab in ipairs(tabs) do if tab == self.tab then active = i; break end end
    local edge = math.max(1, math.floor(NAVBAR_HEIGHT * .012))
    local inset_y = math.max(4, math.floor(NAVBAR_HEIGHT * .07))
    bb:paintRect(x, y, width, NAVBAR_HEIGHT, BB.COLOR_GRAY_E)
    bb:paintRect(x, y, width, edge, BB.COLOR_BLACK)
    local cell = math.floor(width / #tabs)
    for i, tab in ipairs(tabs) do
        local icon = icons[({home=1, bookshelf=2, stats=3, showcase=4})[tab]]
        local left = x + (i - 1) * cell
        local side_inset = math.max(4, math.floor(cell * .025))
        if i > 1 then bb:paintRect(left, y + inset_y, 1, NAVBAR_HEIGHT - inset_y * 2, BB.COLOR_GRAY_C) end
        if i == active then bb:paintRect(left + side_inset, y + inset_y, cell - side_inset * 2, NAVBAR_HEIGHT - inset_y * 2, BB.COLOR_GRAY_4) end
        local plaque = math.max(28, math.floor(NAVBAR_HEIGHT * .58))
        local plaque_x = left + math.floor((cell - plaque) / 2)
        local plaque_y = y + math.floor((NAVBAR_HEIGHT - plaque) / 2)
        if i == active then icon = icon:gsub("%.svg$", "-active.svg") end
        local icon_size = math.max(33, math.floor(NAVBAR_HEIGHT * .66))
        drawPluginIcon(bb, icon, left + math.floor((cell - icon_size) / 2), y + math.floor((NAVBAR_HEIGHT - icon_size) / 2), icon_size)
    end
end

function Shelf:invalidateHomeRenderCache()
    local cached = self._home_render_cache
    if cached and cached.bb and cached.bb.free then pcall(cached.bb.free, cached.bb) end
    self._home_render_cache = nil
    self._home_render_generation = (tonumber(self._home_render_generation) or 0) + 1
end

function Shelf:startHomeClockRefresh()
    if self.home_clock_refresh_running then return end
    self.home_clock_refresh_running=true
    local function tick()
        if Shelf.instance~=self then self.home_clock_refresh_running=false; return end
        if self.tab=="home" then self:invalidateHomeRenderCache(); UIManager:setDirty(self,"ui") end
        local seconds=tonumber(os.date("%S")) or 0
        UIManager:scheduleIn(math.max(5,60-seconds),tick)
    end
    local seconds=tonumber(os.date("%S")) or 0
    UIManager:scheduleIn(math.max(2,60-seconds),tick)
end

function Shelf:setTab(tab)
    if tab ~= "home" and tab ~= "bookshelf" and tab ~= "stats" and tab ~= "showcase" then return end
    if not navigationTabEnabled(tab) then return end
    local perf_started = os.clock()
    self.tab = tab
    self.hit_books = {}
    if tab=="home" then self:startHomeClockRefresh() end
    if tab == "bookshelf" then self:buildPages()
    elseif tab == "showcase" then self:buildShowcasePages() end
    UIManager:setDirty(self, "full")
    local perf_elapsed = os.clock() - perf_started
    if perf_elapsed >= 0.2 then
        logger.info("simplebookshelf: setTab", tab, "elapsed", string.format("%.3fs", perf_elapsed))
    end
end

function Shelf:onTapNav(_, gesture)
    local width = Screen:getWidth()
    local tabs = enabledNavigationTabs()
    local index = math.floor((gesture.pos.x / math.max(1, width)) * #tabs) + 1
    self:setTab(tabs[math.max(1, math.min(#tabs, index))])
    return true
end

function Shelf:onHoldNav()
    -- Global settings belong to the corresponding navigation item.  A hold
    -- on an empty page area must remain inert, so a book/shelf tap cannot
    -- accidentally open configuration.
    if self.tab == "home" then
        self:showHomeSettings()
    elseif self.tab == "bookshelf" then
        self:showGlobalSettings()
    elseif self.tab == "stats" then
        self:showStatsSettings()
    elseif self.tab == "showcase" then
        self:showShowcaseSettings()
    end
    return true
end

function Shelf:showHomeSettings()
    local Menu = require("ui/widget/menu")
    local menu
    local items = {}
    for _, option in ipairs(HOME_BOARD_OPTIONS) do
        local saved = option.key
        items[#items + 1] = {
            text_func=function() return (homeBoardEnabled(saved) and "☑ " or "□ ") .. option.label end,
            callback=function()
                local enabled = homeBoardEnabled(saved)
                local count = 0
                for _, candidate in ipairs(HOME_BOARD_OPTIONS) do if homeBoardEnabled(candidate.key) then count = count + 1 end end
                if enabled then
                    if count <= 1 then return end
                elseif count >= 4 then
                    return
                end
                store:saveSetting("home_board_" .. saved, not enabled); store:flush()
                self:invalidateHomeRenderCache()
                refreshTopMenu()
                UIManager:setDirty(self, "full")
            end,
        }
    end
    menu = Menu:new{title="阅读主页看板", item_table=items, width=math.floor(Screen:getWidth() * .72), height=math.floor(Screen:getHeight() * .58), items_font_size=PLUGIN_MENU_FONT_SIZE, items_mandatory_font_size=PLUGIN_MENU_FONT_SIZE}
    standardizePluginMenu(menu); UIManager:show(menu)
end

function Shelf:showNavigationSettings()
    local Menu = require("ui/widget/menu")
    local menu = Menu:new{items_font_size=PLUGIN_MENU_FONT_SIZE, items_mandatory_font_size=PLUGIN_MENU_FONT_SIZE, title="Reading Line 设置", item_table={
        {text="书柜全局设置", callback=function() UIManager:close(menu); self:showGlobalSettings() end},
        {text="统计页面设置", callback=function() UIManager:close(menu); self:showStatsSettings() end},
        {text="陈列架全局设置", callback=function() UIManager:close(menu); self:showShowcaseSettings() end},
        {text="当前页面：" .. ({home="阅读主页",bookshelf="书柜",stats="统计",showcase="陈列架"})[self.tab], enabled_func=function() return false end},
    }, width=math.floor(Screen:getWidth() * .72), height=math.floor(Screen:getHeight() * .42)}
    local geometry = navColumnMenuGeometry(self.tab, .42)
    standardizePluginMenu(menu); UIManager:show(menu, nil, nil, geometry.x, geometry.y)
end

function Shelf:showStatsSettings()
    local Menu = require("ui/widget/menu")
    local menu
    local function fontOptions()
        local items = {{
            text="默认字体",
            checked_func=function() return readingLineFontFace() == "cfont" end,
            callback=function()
                store:saveSetting("reading_line_font", "cfont")
                store:flush()
                UIManager:close(menu)
                self:invalidateHomeRenderCache()
                UIManager:setDirty(self, "full")
            end,
        }}
        local ok, FontList = pcall(require, "fontlist")
        if ok and FontList and FontList.getFontList then
            for _, face in ipairs(FontList:getFontList() or {}) do
                local saved_face = face
                local display_name = tostring(saved_face):gsub("\\", "/"):match("([^/]+)$") or tostring(saved_face)
                display_name = display_name:gsub("%.[Tt][Tt][Ff]$", "")
                    :gsub("%.[Oo][Tt][Ff]$", "")
                    :gsub("%.[Tt][Tt][Cc]$", "")
                items[#items + 1] = {
                    text=display_name,
                    checked_func=function() return readingLineFontFace() == saved_face end,
                    callback=function()
                        store:saveSetting("reading_line_font", saved_face)
                        store:flush()
                        UIManager:close(menu)
                        self:invalidateHomeRenderCache()
                        UIManager:setDirty(self, "full")
                    end,
                }
            end
        end
        return items
    end
    local function flag(key, label, default)
        return {text_func=function()
            local value = store:readSetting("reading_line_" .. key)
            if value == nil then value = default end
            return label .. "：" .. (value and "开" or "关")
        end, callback=function()
            local value = store:readSetting("reading_line_" .. key)
            if value == nil then value = default end
            store:saveSetting("reading_line_" .. key, not value); store:flush()
            UIManager:setDirty(self, "ui")
        end}
    end
    local function statsOptionItems()
        local items = {}
        local labels = {day="日", week="周", month="月", year="年", screen="阅读"}
        for _, view in ipairs({"day", "week", "month", "year", "screen"}) do
            local saved_view = view
            items[#items + 1] = {
                text_func=function()
                    return (statsOptionEnabled(saved_view) and "☑ " or "□ ") .. labels[saved_view]
                end,
                callback=function()
                    local enabled = statsOptionEnabled(saved_view)
                    local count = 0
                    for _, candidate in ipairs({"day", "week", "month", "year", "screen"}) do
                        if statsOptionEnabled(candidate) then count = count + 1 end
                    end
                    if enabled and count <= 1 then return end
                    store:saveSetting("stats_option_" .. saved_view, not enabled)
                    store:flush()
                    if self.stats_view == saved_view and not statsOptionEnabled(saved_view) then
                        self.stats_view = enabledStatsViews()[1]
                    end
                    UIManager:setDirty(self, "full")
                end,
            }
        end
        return items
    end
    local geometry = navColumnMenuGeometry(self.tab, .72)
    menu = Menu:new{items_font_size=PLUGIN_MENU_FONT_SIZE, items_mandatory_font_size=PLUGIN_MENU_FONT_SIZE, item_table={
        {text="字体", sub_item_table=fontOptions()},
        {text="选项", sub_item_table=statsOptionItems()},
    }, x=geometry.x, y=geometry.y, width=geometry.width, height=geometry.height}
    standardizePluginMenu(menu); UIManager:show(menu, nil, nil, geometry.x, geometry.y)
end

function Shelf:showShowcaseSettings()
    local Menu = require("ui/widget/menu")
    local menu
    local function choose(key, values, labels)
        local items = {}
        for i, value in ipairs(values) do
            local saved = value
            items[#items + 1] = {
                text = labels[i],
                checked_func = function() return showcaseSetting(key) == saved end,
                callback = function()
                    saveShowcase(key, saved)
                    if key == "rows" or key == "book_gap" or key == "book_scale" or key == "book_depth"
                            or key == "margin_left" or key == "margin_right"
                            or key == "sort_mode" then self:buildShowcasePages() end
                    UIManager:close(menu); UIManager:setDirty(self, "ui")
                end,
            }
        end
        return items
    end
    local wallpaper_items = {{text="不使用陈列架壁纸", callback=function()
        store:saveSetting("showcase_wallpaper_enabled", false); store:saveSetting("showcase_wallpaper_path", false); store:flush(); self:clearWallpaperCache(); UIManager:setDirty(self,"ui")
    end}}
    for _, wallpaper in ipairs(scanWallpapersAt(showcaseWallpaperDir())) do
        local item = wallpaper
        wallpaper_items[#wallpaper_items+1] = {text=item.label, checked_func=function() return showcaseWallpaperEnabled() and showcaseWallpaperPath() == item.path end,
            callback=function() store:saveSetting("showcase_wallpaper_path", item.path); store:saveSetting("showcase_wallpaper_enabled", true); store:flush(); self:clearWallpaperCache(); UIManager:setDirty(self,"ui") end}
    end
    wallpaper_items[#wallpaper_items+1] = {text="选择其他壁纸文件夹…", callback=function()
        local PathChooser = require("ui/widget/pathchooser")
        UIManager:close(menu)
        UIManager:show(PathChooser:new{path=showcaseWallpaperDir(), select_directory=true, select_file=false, show_files=false,
            onConfirm=function(folder) store:saveSetting("showcase_wallpaper_dir", folder); store:saveSetting("showcase_wallpaper_path", false); store:saveSetting("showcase_wallpaper_enabled", false); store:flush(); self:clearWallpaperCache(); UIManager:setDirty(self,"ui") end})
    end}
    local fit_items = choose("wallpaper_fit_mode", {"fill", "stretch", "original"}, {"填充", "拉伸", "原始比例"})
    local geometry = navColumnMenuGeometry(self.tab, .72)
    menu = Menu:new{items_font_size=PLUGIN_MENU_FONT_SIZE, items_mandatory_font_size=PLUGIN_MENU_FONT_SIZE, item_table={
        {text="立体度", sub_item_table={
            {text="书本", sub_item_table=choose("book_depth", {1, 2, 3, 4}, {"一档", "二档", "三档", "四档"})},
            {text="书架", sub_item_table=choose("shelf_depth", {0, 1, 2, 3}, {"一档", "二档", "三档", "四档"})},
        }},
        {text="隔板", sub_item_table={
            {text="行数", sub_item_table=choose("rows", {2, 3, 4, 5}, {"两层", "三层", "四层", "五层"})},
            {text="厚度", sub_item_table=choose("shelf_thickness", {4, 6, 8, 12, 16}, {"很薄", "较薄", "默认", "较厚", "很厚"})},
        }},
        {text="全局默认", sub_item_table={
            {text="左边距", sub_item_table=choose("margin_left", {8, 24, 48, 80, 120}, {"8 px · 很窄", "24 px · 较窄", "48 px · 默认", "80 px · 较宽", "120 px · 很宽"})},
            {text="右边距", sub_item_table=choose("margin_right", {8, 24, 48, 80, 120}, {"8 px · 很窄", "24 px · 较窄", "48 px · 默认", "80 px · 较宽", "120 px · 很宽"})},
            {text="书本间距", sub_item_table=choose("book_gap", {4, 8, 10, 14, 20}, {"很窄", "较窄", "默认", "较宽", "很宽"})},
            {text="排序方式", sub_item_table=choose("sort_mode", {"status", "title", "added", "read"}, {"状态", "书名", "添加日期", "阅读日期"})},
            {text="书本比例大小", sub_item_table=choose("book_scale", {80, 100, 120, 140, 160}, {"80%", "100%", "120%", "140%", "160%"})},
        }},
        {text="壁纸", sub_item_table={
            {text_func=function() return "文件夹：" .. showcaseWallpaperDir() end, enabled_func=function() return false end},
            {text="选择壁纸", sub_item_table=wallpaper_items},
            {text="填充方式", sub_item_table=fit_items},
        }},
    }, x=geometry.x, y=geometry.y, width=geometry.width, height=geometry.height}
    standardizePluginMenu(menu); UIManager:show(menu, nil, nil, geometry.x, geometry.y)
end

function Shelf:getShowcaseFilter()
    -- The showcase is a visual browsing surface, not a second category
    -- browser. Always show the complete collection, including when an older
    -- plugin version left a saved filter behind.
    return {label="全部书籍", kind="all", value=""}
end

function Shelf:showcaseBookMatches(book, filter)
    if not filter or filter.kind == "all" then return true end
    if filter.kind == "language" then
        return bookLanguage(book) == filter.value
    end
    if filter.kind == "topic" and filter.value == "feminism" then
        local text = bookSearchText(book)
        for _, term in ipairs(FEMINISM_TERMS) do
            if text:find(term, 1, true) then return true end
        end
        return false
    end
    if filter.kind == "keyword" then
        return bookSearchText(book):find(tostring(filter.value or ""):lower(), 1, true) ~= nil
    end
    return true
end

function Shelf:paintStats(bb, x, y, width, height)
    local SQ3 = require("lua-ljsqlite3/init")
    local db = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local books, seconds, pages, days = 0, 0, 0, 0
    local ok, err = pcall(function()
        local conn = SQ3.open(db)
        books, seconds, pages = conn:rowexec("SELECT count(*), coalesce(sum(total_read_time), 0), coalesce(sum(total_read_pages), 0) FROM book")
        days = conn:rowexec("SELECT count(DISTINCT strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime')) FROM page_stat")
        conn:close()
    end)
    if not ok then logger.warn("simplebookshelf: statistics read failed", err) end
    books, seconds, pages, days = tonumber(books) or 0, tonumber(seconds) or 0, tonumber(pages) or 0, tonumber(days) or 0
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    drawText(bb, "阅读统计", x + 18, y + 18, 24, true)
    drawText(bb, "动态读取 KOReader statistics.sqlite3", x + 18, y + 50, 12, false, nil, BB.COLOR_GRAY_8)
    local metrics = {{"累计时长", string.format("%dh %02dm", hours, minutes)}, {"阅读页数", tostring(pages)}, {"阅读天数", tostring(days)}, {"记录书籍", tostring(books)}}
    local card_w, card_h = math.floor((width - 48) / 2), 78
    for i, metric in ipairs(metrics) do
        local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
        local cx, cy = x + 16 + col * (card_w + 16), y + 86 + row * (card_h + 16)
        bb:paintRect(cx, cy, card_w, card_h, BB.COLOR_GRAY_E)
        bb:paintRect(cx, cy, card_w, 2, BB.COLOR_BLACK)
        drawText(bb, metric[1], cx + 12, cy + 14, 13, false, card_w - 24, BB.COLOR_GRAY_8)
        drawText(bb, metric[2], cx + 12, cy + 38, 22, true, card_w - 24)
    end
    drawText(bb, ok and "数据已从 KOReader 原生统计库读取" or "统计库暂不可用，请确认 KOReader 统计插件已启用", x + 18, y + 278, 12, false, width - 36, ok and BB.COLOR_GRAY_8 or BB.COLOR_BLACK)
end

local function rlTime(seconds)
    seconds = math.max(0, tonumber(seconds) or 0)
    return string.format("%dh %02dm", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60))
end

local function rlWordsPerPage()
    return readingWordsPerPageSetting()
end

local function rlFormatWords(words)
    words = math.max(0, math.floor((tonumber(words) or 0) + .5))
    if words >= 10000 then
        local value = string.format("%.1f", words / 10000):gsub("%.0$", "")
        return value .. " 万字"
    end
    return tostring(words) .. " 字"
end

local function rlDate(ts)
    return os.date("%Y.%m.%d", tonumber(ts) or os.time())
end

local RL_CN_WEEKDAYS = {"周一", "周二", "周三", "周四", "周五", "周六", "周日"}
local RL_EN_WEEKDAYS = {"MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"}

local function rlWeekday(ts)
    local wday = tonumber(os.date("%w", tonumber(ts) or os.time())) or 0
    local index = wday == 0 and 7 or wday
    return RL_CN_WEEKDAYS[index], RL_EN_WEEKDAYS[index], index
end

local function rlBoardings(rows)
    local result = {}
    local current
    for _, row in ipairs(rows or {}) do
        local gap = current and (row.time - current.last_time) or math.huge
        -- page_stat can contain several checkpoints for one uninterrupted
        -- reading session.  A book switch or a substantial pause is a new
        -- boarding, matching the Reading Line web preview.
        if not current or current.id ~= row.id or gap > 20 * 60 then
            current = {
                id=row.id, title=row.title, time=row.time, last_time=row.time,
                duration=tonumber(row.duration) or 0,
                first_page=row.display_page or row.page,
                last_page=row.display_page or row.page,
                rows=1, source_rows={row},
            }
            result[#result + 1] = current
        else
            current.last_time = row.time
            current.duration = current.duration + (tonumber(row.duration) or 0)
            current.last_page = row.display_page or row.page
            current.rows = current.rows + 1
            current.source_rows[#current.source_rows + 1] = row
        end
    end
    return result
end

local function rlDayStart(ts)
    local d = os.date("*t", ts or os.time())
    return os.time{year=d.year, month=d.month, day=d.day, hour=0, min=0, sec=0}
end

function Shelf:readingRows(from_ts, to_ts)
    local db_path = DataStorage:getSettingsDir() .. "/statistics.sqlite3"
    local db_mtime = tonumber(lfs.attributes(db_path, "modification")) or 0
    local cache_key = tostring(from_ts) .. ":" .. tostring(to_ts) .. ":" .. tostring(db_mtime)
    self._reading_rows_cache = self._reading_rows_cache or {order={}}
    local cached = self._reading_rows_cache[cache_key]
    if cached and os.time() - cached.saved_at <= 15 then return cached.rows, cached.ok end
    local rows = {}
    local ok, err = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(db_path)
        -- page_stat is a read-only view in KOReader.  Keep the source rowid
        -- from page_stat_data so the ticket can edit/delete bad records.
        local stmt = conn:prepare([[SELECT psd.rowid, psd.start_time, psd.duration, psd.page,
            b.id, b.title, psd.total_pages, b.pages,
            b.total_read_time, b.total_read_pages, b.authors, b.md5
            FROM page_stat_data psd JOIN book b ON b.id = psd.id_book
            WHERE psd.start_time >= ? AND psd.start_time < ?
            ORDER BY psd.start_time ASC;]])
        local row = stmt:reset():bind(from_ts, to_ts):step()
        while row do
            local row_time, remaining = tonumber(row[2]) or 0, math.max(0, tonumber(row[3]) or 0)
            local page = tonumber(row[4]) or 0
            local source_pages = tonumber(row[7]) or 0
            local local_pages = tonumber(row[8]) or 0
            local display_page = page
            if source_pages > 0 and local_pages > 0 then
                display_page = math.max(0, math.floor(page * local_pages / source_pages + .5))
            end
            repeat
                local local_date = os.date("*t", row_time)
                local next_midnight = os.time{year=local_date.year, month=local_date.month, day=local_date.day + 1, hour=0, min=0, sec=0}
                local local_day = os.date("%Y-%m-%d", row_time)
                local local_next_day = os.date("%Y-%m-%d", row_time + 86400)
                local segment = remaining
                if local_day ~= local_next_day then
                    segment = math.min(remaining, math.max(1, next_midnight - row_time))
                end
                rows[#rows + 1] = {
                    rowid=tonumber(row[1]) or 0, time=row_time,
                    source_time=tonumber(row[2]) or row_time,
                    duration=segment, page=page, display_page=display_page,
                    id=tonumber(row[5]) or 0, title=tostring(row[6] or "未知书籍"),
                    source_pages=source_pages, local_pages=local_pages, pages=local_pages,
                    total_time=tonumber(row[9]) or 0,
                    total_pages=tonumber(row[10]) or 0, authors=tostring(row[11] or ""),
                    md5=tostring(row[12] or ""),
                }
                if segment >= remaining or remaining <= 0 then break end
                remaining = remaining - segment
                row_time = next_midnight
            until false
            row = stmt:step()
        end
        stmt:close()

        -- Reading duration must follow KOReader's bundled statistics plugin,
        -- whose canonical source is the page_stat view (not page_stat_data).
        -- Keep our source-page rows for cross-device page conversion, but
        -- proportion their durations to page_stat's per-book/per-day totals.
        local canonical = {}
        local cstmt = conn:prepare([[
            SELECT b.id,
                   strftime('%Y-%m-%d', ps.start_time, 'unixepoch', 'localtime') AS day,
                   sum(ps.duration)
            FROM page_stat ps JOIN book b ON b.id = ps.id_book
            WHERE ps.start_time >= ? AND ps.start_time < ?
            GROUP BY b.id, day;
        ]])
        local crow = cstmt:reset():bind(from_ts, to_ts):step()
        while crow do
            canonical[tostring(crow[1]) .. "\0" .. tostring(crow[2])] = math.max(0, tonumber(crow[3]) or 0)
            crow = cstmt:step()
        end
        cstmt:close()
        local raw_totals = {}
        for _, item in ipairs(rows) do
            local day = os.date("%Y-%m-%d", item.source_time or item.time)
            local key = tostring(item.id) .. "\0" .. day
            raw_totals[key] = (raw_totals[key] or 0) + (tonumber(item.duration) or 0)
        end
        for _, item in ipairs(rows) do
            local day = os.date("%Y-%m-%d", item.source_time or item.time)
            local key = tostring(item.id) .. "\0" .. day
            local raw_total, canonical_total = raw_totals[key] or 0, canonical[key]
            item.raw_duration = item.duration
            if canonical_total and raw_total > 0 then
                item.duration = (tonumber(item.duration) or 0) * canonical_total / raw_total
            end
        end
        conn:close()
    end)
    if not ok then logger.warn("simplebookshelf: reading line query failed", err) end
    local cache = self._reading_rows_cache
    cache[cache_key] = {rows=rows, ok=ok, saved_at=os.time()}
    cache.order[#cache.order+1] = cache_key
    while #cache.order > 8 do local old=table.remove(cache.order,1); cache[old]=nil end
    return rows, ok
end

-- Keep the calendar data semantics identical to KOReader's bundled
-- statistics.koplugin:getReadBookByDay().  In particular, books are ordered
-- by reading duration for each day before the three visual lanes are built.
function Shelf:readingCalendarBooks(year, month)
    local per_day = {}
    local ok, err = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
        local stmt = conn:prepare([[
            SELECT
                strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime') day,
                sum(duration) durations,
                id_book book_id,
                title book_title
            FROM (
                SELECT start_time, duration, page_stat.id_book, book.title
                FROM page_stat
                JOIN book ON book.id = page_stat.id_book
                WHERE start_time BETWEEN strftime('%s', ?, 'utc')
                                     AND strftime('%s', ?, 'utc', '+33 days', 'start of month', '-1 second')
            )
            GROUP BY
                strftime('%Y-%m-%d', start_time, 'unixepoch', 'localtime'),
                id_book,
                title
            ORDER BY day, durations DESC, book_id, book_title;
        ]])
        local month_key = string.format("%04d-%02d-01", year, month)
        local res, count = stmt:reset():bind(month_key, month_key):resultset("i")
        stmt:close()
        conn:close()
        for i = 1, count do
            local day, book_id, book_title = res[1][i], res[3][i], res[4][i]
            if day then
                per_day[day] = per_day[day] or {}
                per_day[day][#per_day[day] + 1] = {id=tonumber(book_id) or 0, title=tostring(book_title or "未知书籍")}
            end
        end
    end)
    if not ok then logger.warn("simplebookshelf: calendar query failed", err) end
    return per_day, ok
end

local function rlCalendarWeeks(year, month, days, first_wday, per_day, lane_count)
    lane_count = lane_count or 3
    local weeks = {}
    for week_index = 1, 6 do
        local week = {days_books={}}
        local previous_day_books
        for col = 1, 7 do
            local slot = (week_index - 1) * 7 + col - 1
            local day_num = slot - first_wday + 1
            local read_books = {}
            if day_num >= 1 and day_num <= days then
                local key = string.format("%04d-%02d-%02d", year, month, day_num)
                read_books = per_day[key] or {}
            end
            local this_day_books = {}
            week.days_books[col] = this_day_books
            for lane = 1, lane_count do
                local source = read_books[lane]
                if source then
                    this_day_books[lane] = {id=source.id, title=source.title, span_days=1, start_day=col, fixed=false}
                else
                    this_day_books[lane] = false
                end
            end
            if previous_day_books then
                for previous_lane = 1, lane_count do
                    local previous_book = previous_day_books[previous_lane]
                    if previous_book then
                        for this_lane = 1, lane_count do
                            local this_book = this_day_books[this_lane]
                            if this_book and this_book.id == previous_book.id then
                                this_book.start_day = previous_book.start_day
                                this_book.fixed = true
                                this_book.span_days = previous_book.span_days + 1
                                for back = 1, previous_book.span_days do
                                    local older = week.days_books[col-back][previous_lane]
                                    if older then older.span_days = this_book.span_days end
                                end
                                if this_lane ~= previous_lane then
                                    this_day_books[this_lane], this_day_books[previous_lane] = this_day_books[previous_lane], this_day_books[this_lane]
                                end
                                break
                            end
                        end
                    end
                end
            end
            previous_day_books = this_day_books
        end
        weeks[week_index] = week
    end
    return weeks
end

local function rlAggregate(rows)
    local result = {seconds=0, pages=0, words=0, sessions=0, books={}, days={}}
    local state,seen={},{}
    local text_indexes = store:readSetting("reading_line_text_indexes") or {}
    for _, row in ipairs(rows or {}) do
        result.seconds = result.seconds + (row.duration or 0)
        result.sessions = result.sessions + 1
        local book_key = tostring(row.title or "") .. "\0" .. tostring(row.authors or "")
        local raw_page = math.max(0, tonumber(row.page) or 0)
        local source_total = math.max(0, tonumber(row.source_pages) or 0)
        local local_total = math.max(0, tonumber(row.local_pages) or tonumber(row.pages) or 0)
        if source_total <= 0 then source_total = local_total end
        if local_total <= 0 then local_total = source_total end
        local progress = source_total > 0 and math.max(0, math.min(1, raw_page / source_total)) or raw_page
        local display_page = tonumber(row.display_page) or raw_page
        if local_total > 0 then display_page = math.max(1, math.min(local_total, math.floor(display_page + .5))) end
        local index_key = readingLineTextIndexKey(row.md5, local_total)
        local text_index = index_key and text_indexes[index_key] or nil
        local cumulative = text_index and text_index.cumulative or nil
        local previous = state[book_key]
        local signature=book_key.."\0"..tostring(row.time or 0).."\0"..tostring(raw_page).."\0"..tostring(source_total).."\0"..tostring(row.duration or 0)
        local page_delta = 0
        local word_delta
        if not seen[signature] then
            if not previous then
                page_delta = raw_page > 0 and 1 or 0
                if cumulative and cumulative[display_page] ~= nil and cumulative[display_page + 1] ~= nil then
                    word_delta = math.max(0, cumulative[display_page + 1] - cumulative[display_page])
                end
            elseif progress > previous.progress then
                page_delta = local_total > 0 and (progress - previous.progress) * local_total
                    or math.max(0, raw_page - (previous.raw_page or raw_page))
                if cumulative and previous.index_key == index_key
                        and cumulative[previous.display_page] ~= nil and cumulative[display_page] ~= nil then
                    word_delta = math.max(0, cumulative[display_page] - cumulative[previous.display_page])
                end
            end
            seen[signature] = true
        end
        if word_delta == nil then word_delta = page_delta * rlWordsPerPage() end
        local book_entry = result.books[book_key] or {title=row.title, seconds=0, pages=0, words=0, sessions=0}
        result.pages = result.pages + page_delta
        result.words = result.words + word_delta
        if not previous or progress >= previous.progress then
            state[book_key] = {progress=progress, raw_page=raw_page, display_page=display_page, index_key=index_key}
        end
        result.books[book_key] = book_entry
        book_entry.seconds = book_entry.seconds + (row.duration or 0)
        book_entry.pages = book_entry.pages + page_delta
        book_entry.words = book_entry.words + word_delta
        book_entry.sessions = book_entry.sessions + 1
        local day = os.date("%Y-%m-%d", row.time)
        result.days[day] = result.days[day] or {seconds=0, pages=0, words=0, books={}}
        result.days[day].seconds = result.days[day].seconds + (row.duration or 0)
        result.days[day].pages = result.days[day].pages + page_delta
        result.days[day].words = result.days[day].words + word_delta
        result.days[day].books[book_key] = row.title
    end
    result.pages=math.floor(result.pages+.5); result.words=math.floor(result.words+.5)
    for _,book in pairs(result.books) do book.pages=math.floor(book.pages+.5); book.words=math.floor(book.words+.5) end
    for _,day in pairs(result.days) do day.pages=math.floor(day.pages+.5); day.words=math.floor(day.words+.5) end
    return result
end

local function rlFinishedCount(rows)
    local books = {}
    for _, row in ipairs(rows or {}) do
        local source_total = math.max(0, tonumber(row.source_pages) or tonumber(row.local_pages) or tonumber(row.pages) or 0)
        local progress = source_total > 0 and (tonumber(row.page) or 0) / source_total or 0
        local book = books[row.id] or {max_progress=0}
        book.max_progress = math.max(book.max_progress, progress)
        books[row.id] = book
    end
    local count = 0
    for _, book in pairs(books) do
        if book.max_progress >= .995 and book.max_progress <= 1.05 then count = count + 1 end
    end
    return count
end

function Shelf:syncFinishedSnapshots(rows)
    local snapshots = store:readSetting("reading_line_finished_snapshots") or {}
    local changed = false
    local by_id = {}
    for _, row in ipairs(rows or {}) do
        local bucket = by_id[row.id] or {}
        bucket[#bucket + 1] = row
        by_id[row.id] = bucket
    end
    for id, book_rows in pairs(by_id) do
        local max_progress = 0
        for _, row in ipairs(book_rows) do
            local source_total = math.max(0, tonumber(row.source_pages) or tonumber(row.local_pages) or tonumber(row.pages) or 0)
            local progress = source_total > 0 and (tonumber(row.page) or 0) / source_total or 0
            max_progress = math.max(max_progress, progress)
        end
        if max_progress >= .995 and max_progress <= 1.05 then
            local agg = rlAggregate(book_rows)
            local old = snapshots[tostring(id)]
            local snapshot = {id=id, title=book_rows[1].title, seconds=agg.seconds, pages=agg.pages, words=agg.words, finished_at=book_rows[#book_rows].time}
            if not old or old.seconds ~= snapshot.seconds or old.pages ~= snapshot.pages then
                snapshots[tostring(id)] = snapshot
                changed = true
            end
        end
    end
    if changed then
        store:saveSetting("reading_line_finished_snapshots", snapshots)
        store:flush()
    end
end

local function rlPaintTicketNotches(bb, x, y, w, h, radius, paper_color, sides)
    -- The black outer backing is already behind the paper.  Paint solid
    -- black half-discs into the paper edge so the notch is visibly black and
    -- points inward, rather than leaving a pale circle or a thin outline.
    radius = math.max(5, math.floor(radius or 12))
    sides = sides or {}
    local top = sides.top ~= false
    local bottom = sides.bottom ~= false
    local left = sides.left ~= false
    local right = sides.right ~= false
    local black = BB.COLOR_BLACK
    local mid_x = sides.notch_x or (x + math.floor(w / 2))
    local mid_y = sides.notch_y or (y + math.floor(h / 2))
    if sides.stamp then
        local function half_disc(cx, cy, edge)
            for row = 0, radius do
                local span = math.max(0, math.floor(math.sqrt(radius * radius - row * row)))
                if edge == "top" then
                    bb:paintRect(cx - span, y + row, span * 2 + 1, 1, black)
                elseif edge == "bottom" then
                    bb:paintRect(cx - span, y + h - row - 1, span * 2 + 1, 1, black)
                elseif edge == "left" then
                    bb:paintRect(x + row, cy - span, 1, span * 2 + 1, black)
                else
                    bb:paintRect(x + w - row - 1, cy - span, 1, span * 2 + 1, black)
                end
            end
        end
        local step = math.max(radius * 3, 24)
        for cx = x + radius * 2, x + w - radius * 2, step do
            if top then half_disc(cx, mid_y, "top") end
            if bottom then half_disc(cx, mid_y, "bottom") end
        end
        for cy = y + radius * 2, y + h - radius * 2, step do
            if left then half_disc(mid_x, cy, "left") end
            if right then half_disc(mid_x, cy, "right") end
        end
        return
    end
    for row = 0, radius do
        -- At the ticket edge the notch is widest; it narrows toward the
        -- inside of the ticket.  Using (radius-row) here reverses the arc
        -- and creates the upside-down wedge seen on the device.
        local span = math.max(0, math.floor(math.sqrt(radius * radius - row * row)))
        if top then bb:paintRect(mid_x - span, y + row, span * 2 + 1, 1, black) end
        if bottom then bb:paintRect(mid_x - span, y + h - row - 1, span * 2 + 1, 1, black) end
        if left then bb:paintRect(x + row, mid_y - span, 1, span * 2 + 1, black) end
        if right then bb:paintRect(x + w - row - 1, mid_y - span, 1, span * 2 + 1, black) end
    end
end

local function rlDrawTicketFrame(bb, x, y, w, h, dark)
    -- Soft offset shadow, matching the paper ticket instead of four dark dots.
    bb:paintRect(x + 6, y + 8, w, h, dark and BB.COLOR_GRAY_8 or BB.COLOR_GRAY_C)
    bb:paintRect(x - 5, y - 5, w + 10, h + 10, BB.COLOR_BLACK)
    bb:paintRect(x, y, w, h, dark and BB.COLOR_GRAY_E or BB.COLOR_WHITE)
    bb:paintRect(x, y, w, 2, BB.COLOR_BLACK)
    bb:paintRect(x, y + h - 2, w, 2, BB.COLOR_GRAY_8)
    -- Preserve the web ticket's inset frame and perforations.
    bb:paintRect(x + 15, y + 15, w - 30, 1, BB.COLOR_GRAY_C)
    bb:paintRect(x + 15, y + h - 16, w - 30, 1, BB.COLOR_GRAY_C)
    bb:paintRect(x + 15, y + 15, 1, h - 30, BB.COLOR_GRAY_C)
    bb:paintRect(x + w - 16, y + 15, 1, h - 30, BB.COLOR_GRAY_C)
    rlPaintTicketNotches(bb, x, y, w, h, 54, dark and BB.COLOR_GRAY_E or BB.COLOR_WHITE)
end

local function rlTicketHeader(bb, x, y, w, kicker, title, subtitle, meta)
    -- Keep the header as a real ticket header. The old coordinates put the
    -- kicker, title and subtitle on top of one another on Kindle's larger
    -- portrait canvases; the browser preview happened to hide that because
    -- its font metrics are different.
    local main_w = math.max(180, w - 205)
    drawText(bb, kicker, x + 24, y + 16, 11, false, main_w, BB.COLOR_GRAY_8)
    drawText(bb, title, x + 24, y + 38, 32, true, main_w)
    drawText(bb, subtitle, x + 24, y + 82, 10, false, main_w, BB.COLOR_GRAY_8)
    bb:paintRect(x + 20, y + 111, w - 40, 1, BB.COLOR_GRAY_8)
    if type(meta) == "table" then
        for line_y = y + 12, y + 114, 5 do
            bb:paintRect(x + w - 153, line_y, 1, 2, BB.COLOR_GRAY_8)
        end
        drawText(bb, meta.no or "", x + w - 145, y + 19, 10, false, 120, BB.COLOR_GRAY_8)
        drawText(bb, meta.gate_label or "检票口 · GATE", x + w - 145, y + 39, 8, false, 120, BB.COLOR_GRAY_8)
        drawText(bb, meta.gate or "", x + w - 145, y + 55, 22, true, 120)
        drawText(bb, meta.caption or "日票 · DAY PASS", x + w - 145, y + 87, 8, false, 120)
    elseif meta then
        drawText(bb, meta, x + w - 145, y + 24, 10, true, 120)
    end
end

local function rlFacts(bb, x, y, w, items)
    local cell = math.floor((w - 48) / #items)
    for i, item in ipairs(items) do
        local cx = x + 24 + (i - 1) * cell
        if i > 1 then bb:paintRect(cx - 10, y + 2, 1, 30, BB.COLOR_GRAY_8) end
        drawText(bb, item[1], cx, y, 8, false, cell - 8, BB.COLOR_GRAY_8)
        drawText(bb, item[2], cx, y + 15, 11, true, cell - 8)
    end
end

local function rlSummary(bb, x, y, w, items)
    local cell = math.floor((w - 40) / #items)
    bb:paintRect(x + 20, y, w - 40, 1, BB.COLOR_GRAY_8)
    for i, item in ipairs(items) do
        local cx = x + 20 + (i - 1) * cell
        if i > 1 then bb:paintRect(cx, y + 8, 1, 42, BB.COLOR_GRAY_8) end
        drawText(bb, item[1], cx + 8, y + 9, 8, false, cell - 14, BB.COLOR_GRAY_8)
        drawText(bb, item[2], cx + 8, y + 27, 13, true, cell - 14)
    end
end

local function rlBarcode(bb, x, y, w, h, seed)
    seed = tostring(seed or "READING-LINE")
    bb:paintRect(x, y, w, h, BB.COLOR_WHITE)
    local cursor = x + 2
    local code = 0
    for i = 1, #seed do code = (code + seed:byte(i) * i) % 17 end
    -- Use the looser, irregular rhythm from the physical reference ticket:
    -- wider bars and visibly separated gaps.  The old 1-4px bars with 1-3px
    -- gaps produced a nearly solid gray band on e-ink.
    while cursor < x + w - 2 do
        code = (code * 13 + 7) % 17
        local bar_sizes = {2, 4, 7, 3, 11, 5, 8, 2, 13, 6}
        local gap_sizes = {6, 11, 7, 15, 9, 5, 13}
        local bar = bar_sizes[(code % #bar_sizes) + 1]
        local gap = gap_sizes[((code * 3) % #gap_sizes) + 1]
        bb:paintRect(cursor, y + 2, bar, h - 4, BB.COLOR_BLACK)
        cursor = cursor + bar + gap
    end
end

local function rlMetricIcon(bb, filename, x, y, size)
    local ImageWidget = require("ui/widget/imagewidget")
    local path = PLUGIN_DIR .. "/train-icons-svg/" .. filename
    if not lfs.attributes(path, "mode") then return end
    local ok, widget = pcall(function()
        return ImageWidget:new{file=path, width=size, height=size, alpha=true, file_do_cache=false}
    end)
    if ok and widget then
        pcall(widget.paintTo, widget, bb, x, y)
        if widget.free then widget:free() end
    end
end

local function rlBarcodeNav(bb, x, y, w, h, seed)
    bb:paintRect(x, y, w, h, BB.COLOR_WHITE)
    local mid = y + math.floor(h / 2)
    -- Larger triangular controls, with a generous surrounding hit box.
    local half = math.max(8, math.floor(h * .36))
    for row = 0, half do
        local span = math.max(2, half - row + 2)
        bb:paintRect(x + 12 + row, mid - row, span, 1, BB.COLOR_BLACK)
        bb:paintRect(x + 12 + row, mid + row, span, 1, BB.COLOR_BLACK)
        bb:paintRect(x + w - 12 - row - span, mid - row, span, 1, BB.COLOR_BLACK)
        bb:paintRect(x + w - 12 - row - span, mid + row, span, 1, BB.COLOR_BLACK)
    end
    rlBarcode(bb, x + 48, y, w - 96, h, seed)
end

local RL_VIEWS = {"day", "week", "month", "year", "screen"}
local RL_VIEW_LABELS = {day="日票", week="周票", month="月票", year="年票", screen="阅读车票"}

local function rlReadingFooter(owner, bb, x, y, w, h, seed, caption)
    local nav_h = math.max(20, math.min(30, math.floor(h * .035)))
    local barcode_x, barcode_y = x + 48, y + h - 66
    local barcode_w = math.max(120, w - 96)
    if store:readSetting("reading_line_show_barcode") ~= false then
        if owner.stats_view == "screen" then
            rlBarcode(bb, x + 38, barcode_y, math.max(120, w - 76), nav_h, seed)
        else
            rlBarcodeNav(bb, barcode_x, barcode_y, barcode_w, nav_h, seed)
        end
        drawCenteredText(bb, caption or "READING LINE", x + 40, y + h - 43, 8, false, w - 80, BB.COLOR_GRAY_8)
    end
    local dots_y = y + h - 17
    local active = 1
    local visible_views = enabledStatsViews()
    for i, view in ipairs(visible_views) do if owner.stats_view == view then active = i; break end end
    owner.stats_nav_hit = {dots={}}
    for i, view in ipairs(visible_views) do
        local cx = x + math.floor(w / 2) - math.floor((#visible_views - 1) * 9) + (i - 1) * 18
        if bb.paintCircle then
            pcall(bb.paintCircle, bb, cx, dots_y, math.max(2, math.floor((i == active and 5 or 4))), i == active and BB.COLOR_BLACK or BB.COLOR_GRAY_8)
        else
            bb:paintRect(cx - 2, dots_y - 2, 4, 4, i == active and BB.COLOR_BLACK or BB.COLOR_GRAY_8)
        end
        owner.stats_nav_hit.dots[i] = {x=cx-10, y=dots_y-10, w=20, h=20, view=view}
    end
    if owner.stats_view ~= "screen" then
        owner.stats_nav_hit.prev = {x=barcode_x, y=barcode_y-8, w=42, h=nav_h+16}
        owner.stats_nav_hit.next = {x=barcode_x + barcode_w - 42, y=barcode_y-8, w=42, h=nav_h+16}
    end
    owner.stats_barcode_hit = {x=barcode_x + 42, y=barcode_y-5, w=math.max(40, barcode_w - 84), h=nav_h + 12}
end

-- Week/month/year/screen use the same 1006x1093 reference canvas as the day
-- ticket.  KOReader exposes physical pixels here, so fixed coordinates make
-- a layout that looked acceptable in a browser collapse into the top edge on
-- a 1404x1872 Kindle.  This painter maps every line, glyph and hit target from
-- the reference ticket to the actual device canvas.
local function rlReferencePainter(bb, y, h)
    local viewport_w = Screen:getWidth()
    local s = math.min((viewport_w - 36) / 1006, (h - 24) / 1093)
    local sy = math.max(s, (h - 8) / 1093)
    local ox, oy = (viewport_w - 1006 * s) / 2, y + 4
    local font_s = math.min(s, 1)
    local ui_s = math.min(s, 1.15)
    local function X(v) return math.floor(ox + v * s) end
    local function Y(v) return math.floor(oy + v * sy) end
    local function L(x1, y1, x2, y2, color, thick)
        if x1 == x2 then
            bb:paintRect(X(x1), Y(y1), math.max(1, math.floor((thick or 1) * s)), math.max(1, Y(y2) - Y(y1)), color)
        else
            bb:paintRect(X(x1), Y(y1), math.max(1, X(x2) - X(x1)), math.max(1, math.floor((thick or 1) * s)), color)
        end
    end
    local function DL(x1, y1, x2, y2, color, thick, dash, gap)
        dash, gap = dash or 7, gap or 5
        if y1 == y2 then
            local cursor = x1
            while cursor < x2 do
                L(cursor, y1, math.min(x2, cursor + dash), y2, color, thick)
                cursor = cursor + dash + gap
            end
        else
            local cursor = y1
            while cursor < y2 do
                L(x1, cursor, x2, math.min(y2, cursor + dash), color, thick)
                cursor = cursor + dash + gap
            end
        end
    end
    local function R(rx, ry, rw, rh, color)
        bb:paintRect(X(rx), Y(ry), math.max(1, math.floor(rw * s)), math.max(1, math.floor(rh * sy)), color)
    end
    local function T(text, px, py, size, bold, maxw, color)
        text = tostring(text or "")
        local fitted = math.max(6, math.floor(size * font_s))
        if maxw then
            local estimated = 0
            for _, ch in ipairs(utf8Chars(text)) do estimated = estimated + (ch:byte(1) >= 128 and fitted or fitted * .58) end
            local limit = math.max(10, math.floor(maxw * s))
            if estimated > limit and estimated > 0 then fitted = math.max(6, math.floor(fitted * limit / estimated)) end
        end
        drawText(bb, text, X(px), Y(py), fitted, bold, nil, color)
    end
    local function CT(text, left, top, width_ref, size, bold, color)
        local fitted = math.max(6, math.floor(size * font_s))
        local actual = 0
        local ok_measure, measured = pcall(function()
            local Font = require("ui/font")
            local TextWidget = require("ui/widget/textwidget")
            local widget = TextWidget:new{text=tostring(text or ""), face=Font:getFace(simpleUIFontFace(), fitted), fgcolor=color or BB.COLOR_BLACK}
            local width = widget:getSize().w
            widget:free()
            return width
        end)
        if ok_measure then actual = measured else
            for _, ch in ipairs(utf8Chars(tostring(text or ""))) do actual = actual + (ch:byte(1) >= 128 and fitted or fitted * .58) end
        end
        drawText(bb, tostring(text or ""), X(left) + math.floor((width_ref * s - actual) / 2), Y(top), fitted, bold, nil, color)
    end
    local function M(text, size, color)
        local fitted = math.max(6, math.floor(size * font_s))
        local actual = 0
        local ok_measure, measured = pcall(function()
            local Font = require("ui/font")
            local TextWidget = require("ui/widget/textwidget")
            local widget = TextWidget:new{text=tostring(text or ""), face=Font:getFace(simpleUIFontFace(), fitted), fgcolor=color or BB.COLOR_BLACK}
            local width = widget:getSize().w
            widget:free()
            return width
        end)
        if ok_measure then actual = measured else
            for _, ch in ipairs(utf8Chars(tostring(text or ""))) do actual = actual + (ch:byte(1) >= 128 and fitted or fitted * .58) end
        end
        return actual, fitted
    end
    local function Circle(cx, cy, radius, color)
        local r = math.max(2, math.floor(radius * ui_s))
        if bb.paintCircle then pcall(bb.paintCircle, bb, X(cx), Y(cy), r, color)
        else bb:paintRect(X(cx)-r, Y(cy)-r, r*2, r*2, color) end
    end
    return {X=X, Y=Y, L=L, DL=DL, R=R, T=T, CT=CT, M=M, Circle=Circle, s=s, sy=sy, ui_s=ui_s, font_s=font_s}
end

local function rlEllipsize(text, max_chars)
    local chars = utf8Chars(tostring(text or ""))
    max_chars = math.max(2, tonumber(max_chars) or 8)
    if #chars <= max_chars then return table.concat(chars) end
    local out = {}
    for i = 1, max_chars - 1 do out[#out + 1] = chars[i] end
    return table.concat(out) .. "…"
end

local function rlReferenceFrame(bb, p, notch_spec)
    notch_spec = notch_spec or {}
    p.R(12, 8, 982, 1070, BB.COLOR_BLACK)
    p.R(18, 14, 970, 1064, BB.COLOR_WHITE)
    p.L(18, 14, 988, 14, BB.COLOR_BLACK, 2)
    p.L(18, 14, 18, 1078, BB.COLOR_BLACK, 2)
    p.L(988, 14, 988, 1078, BB.COLOR_BLACK, 2)
    p.L(18, 1078, 988, 1078, BB.COLOR_BLACK, 2)
    p.L(38, 30, 968, 30, BB.COLOR_GRAY_C, 1)
    p.L(38, 1062, 968, 1062, BB.COLOR_GRAY_C, 1)
    p.L(38, 30, 38, 1062, BB.COLOR_GRAY_C, 1)
    p.L(968, 30, 968, 1062, BB.COLOR_GRAY_C, 1)
    local spec = {}
    for key, value in pairs(notch_spec) do spec[key] = value end
    spec.radius = nil
    if spec.notch_x then spec.notch_x = p.X(spec.notch_x) end
    if spec.notch_y then spec.notch_y = p.Y(spec.notch_y) end
    rlPaintTicketNotches(bb, p.X(18), p.Y(14), p.X(988)-p.X(18), p.Y(1078)-p.Y(14), math.max(18, math.floor((notch_spec.radius or 36)*p.s)), BB.COLOR_WHITE, spec)
end

-- One metric composition for week/month/year.  It mirrors the day ticket:
-- icon on the left, aligned English/Chinese labels on the right, then a
-- shared value baseline below.  Keeping it centralized also prevents SVGs
-- disappearing when one ticket is adjusted independently.
local function rlReferenceMetrics(bb, p, items, top, bottom)
    top = top or 789
    bottom = bottom or 910
    local cell = 222
    for i, item in ipairs(items) do
        local cx = 62 + (i - 1) * cell
        if i > 1 then p.L(cx - 12, top + 8, cx - 12, bottom - 8, BB.COLOR_GRAY_C, 1) end
        rlMetricIcon(bb, item[4], p.X(cx), p.Y(top + 14), math.max(28, math.floor(48 * p.ui_s)))
        p.T(item[1], cx + 47, top + 11, 8, false, 135, BB.COLOR_BLACK)
        p.T(item[2], cx + 47, top + 31, 10, false, 135, BB.COLOR_GRAY_8)
        p.T(item[3], cx + 3, top + 68, 25, true, 184, BB.COLOR_BLACK)
        if i == 1 then p.T("↗", cx + 176, top + 12, 8, true, 20, BB.COLOR_GRAY_8) end
    end
end

local function rlReferenceFooter(owner, bb, p, seed, caption, period_nav)
    local barcode_x, barcode_y = p.X(145), p.Y(920)
    local barcode_w = math.floor(716 * p.s)
    -- Day/week/month/year must share the exact same barcode and triangle
    -- scale.  The old 38px reference made every non-day ticket visibly
    -- smaller than the day ticket's 58px control.
    local barcode_h = math.max(12, math.floor(58 * p.ui_s))
    if store:readSetting("reading_line_show_barcode") ~= false then
        if period_nav then rlBarcodeNav(bb, barcode_x, barcode_y, barcode_w, barcode_h, seed)
        else rlBarcode(bb, barcode_x + math.floor(42*p.s), barcode_y, barcode_w - math.floor(84*p.s), barcode_h, seed) end
        p.CT(caption or "READING LINE", 145, 988, 716, 9, false, BB.COLOR_GRAY_8)
    end
    local active = 1
    local visible_views = enabledStatsViews()
    for i, view in ipairs(visible_views) do if owner.stats_view == view then active = i; break end end
    owner.stats_nav_hit = {dots={}}
    for i, view in ipairs(visible_views) do
        local cx = 503 - math.floor((#visible_views - 1) * 9) + (i - 1) * 18
        p.Circle(cx, 1022, i == active and 5 or 4, i == active and BB.COLOR_BLACK or BB.COLOR_GRAY_8)
        owner.stats_nav_hit.dots[i] = {x=p.X(cx)-math.floor(10*p.s), y=p.Y(1022)-math.floor(10*p.s), w=math.floor(20*p.s), h=math.floor(20*p.s), view=view}
    end
    if period_nav then
        owner.stats_nav_hit.prev = {x=barcode_x, y=barcode_y, w=math.floor(48*p.s), h=barcode_h}
        owner.stats_nav_hit.next = {x=barcode_x+barcode_w-math.floor(48*p.s), y=barcode_y, w=math.floor(48*p.s), h=barcode_h}
    end
    owner.stats_barcode_hit = {x=barcode_x+math.floor(48*p.s), y=barcode_y, w=barcode_w-math.floor(96*p.s), h=barcode_h}
end

function Shelf:paintReadingLine(bb, x, y, width, height)
    -- The six ticket types are intentionally gesture-only.  The web preview
    -- uses the ticket itself as the page and does not spend vertical space
    -- on a second tab strip.
    local content_y, content_h = y, height
    -- Statistics pages are tickets on a black field.  Painting this before
    -- the individual white/gray ticket keeps wallpaper from showing around
    -- the outer frame on the e-ink device.
    bb:paintRect(x, y, width, height, BB.COLOR_BLACK)
    self.stats_duration_hit = nil
    if not self._finished_snapshot_at or os.time() - self._finished_snapshot_at >= 30 then
        local all_rows = self:readingRows(0, os.time() + 1)
        self:syncFinishedSnapshots(all_rows)
        self._finished_snapshot_at = os.time()
    end
    if self.stats_view == "day" then self:paintReadingDay(bb, x, content_y, width, content_h)
    elseif self.stats_view == "week" then self:paintReadingWeek(bb, x, content_y, width, content_h)
    elseif self.stats_view == "month" then self:paintReadingMonth(bb, x, content_y, width, content_h)
    elseif self.stats_view == "year" then self:paintReadingYear(bb, x, content_y, width, content_h)
    elseif self.stats_view == "book" then self:paintReadingBook(bb, x, content_y, width, content_h)
    else self:paintReadingScreen(bb, x, content_y, width, content_h) end
end

function Shelf:setStatsView(view)
    local allowed = {day=true, week=true, month=true, year=true, book=true, screen=true}
    if allowed[view] and (view == "book" or statsOptionEnabled(view)) then
        self.stats_view = view
        UIManager:setDirty(self, "full")
    end
end

function Shelf:shiftStatsPeriod(delta)
    local d = os.date("*t", self.stats_date or os.time())
    if self.stats_view == "day" or self.stats_view == "book" or self.stats_view == "screen" then
        d.day = d.day + delta
    elseif self.stats_view == "week" then
        d.day = d.day + delta * 7
    elseif self.stats_view == "month" then
        d.month = d.month + delta; d.day = 1
    elseif self.stats_view == "year" then
        d.year = d.year + delta; d.month = 1; d.day = 1
    end
    self.stats_date = os.time{year=d.year, month=d.month, day=d.day, hour=12, min=0, sec=0}
    self.stats_boarding_page = 1
    UIManager:setDirty(self, "full")
end

function Shelf:paintReadingDay(bb, x, y, w, h)
    self.stats_hit_books = {}
    self.stats_hit_records = {}
    local start = rlDayStart(self.stats_date)
    local rows, ok = self:readingRows(start, start + 86400)
    local boardings = rlBoardings(rows)
    local agg = rlAggregate(rows)
    local cn_weekday, en_weekday, weekday_index = rlWeekday(start)
    -- The reference webpage uses a 1006x1093 ticket coordinate system.
    -- Keep the geometry proportional so the same composition survives on
    -- different Kindle resolutions instead of falling back to a compact card.
    -- Responsive base scale: fit the ticket to the current widget, but never
    -- enlarge the web reference.  KOReader fonts have different metrics from
    -- browser fonts, so each text block is fitted independently below.
    -- The stats canvas may report a reduced logical height while the screen
    -- still has a large portrait surface.  Let width establish the ticket
    -- scale; using that reduced height here turns the ticket into a tiny card.
    local viewport_w = Screen:getWidth()
    local viewport_x = 0
    local s = math.min((viewport_w - 36) / 1006, (h - 36) / 1093)
    -- CSS layout scale and CSS font scale are different: the web ticket's
    -- display sizes have hard maxima (notably the 62px title).  Enlarge the
    -- composition to fill a high-DPI Kindle, but keep glyphs at readable web
    -- sizes so they do not collide with the next row.
    local font_s = math.min(s, 1)
    local ui_s = math.min(s, 1.15)
    if not self._rl_debug_dims_logged then
        logger.warn("simplebookshelf: RL_DIMS", "screen", viewport_w, Screen:getHeight(), "canvas", w, h, "scale", s)
        self._rl_debug_dims_logged = true
    end
    local ox, oy = viewport_x + (viewport_w - 1006 * s) / 2, y + 4
    -- The Kindle portrait viewport is taller than the web ticket ratio.
    -- Keep the horizontal composition intact, but use the full available
    -- height so the ticket is not a small card floating above a blank band.
    local sy = math.max(s, (h - 8) / 1093)
    local function X(v) return math.floor(ox + v * s) end
    local function Y(v) return math.floor(oy + v * sy) end
    local function L(x1, y1, x2, y2, color, thick)
        if x1 == x2 then bb:paintRect(X(x1), Y(y1), math.max(1, math.floor((thick or 1) * s)), math.max(1, Y(y2)-Y(y1)), color)
        else bb:paintRect(X(x1), Y(y1), math.max(1, X(x2)-X(x1)), math.max(1, math.floor((thick or 1) * s)), color) end
    end
    local function DL(x1, y1, x2, y2, color, thick)
        if x1 == x2 then
            local cursor = y1
            while cursor < y2 do
                L(x1, cursor, x2, math.min(y2, cursor + 7), color, thick)
                cursor = cursor + 12
            end
        else
            local cursor = x1
            while cursor < x2 do
                L(cursor, y1, math.min(x2, cursor + 7), y2, color, thick)
                cursor = cursor + 12
            end
        end
    end
    local function T(text, px, py, size, bold, maxw, color)
        -- Do not put the day ticket through a one-line TextBoxWidget.  On
        -- KOReader that widget clips/reflows CJK and large display glyphs at
        -- the edge, producing the broken bands seen on the device.  The web
        -- layout already gives each field its own coordinates, so natural
        -- TextWidget width is the faithful rendering here.
        text = tostring(text or "")
        local fitted = math.max(6, math.floor(size * font_s))
        if maxw then
            local estimated = 0
            for _, ch in ipairs(utf8Chars(text)) do
                estimated = estimated + (ch:byte(1) >= 128 and fitted or fitted * .58)
            end
            local limit = math.max(10, math.floor(maxw * s))
            if estimated > limit and estimated > 0 then
                fitted = math.max(6, math.floor(fitted * limit / estimated))
            end
        end
        drawText(bb, text, X(px), Y(py), fitted, bold, nil, color)
    end
    local function CT(text, left, top, width_ref, size, bold, color)
        -- Center using the actual KOReader font width, not a CJK/Latin guess.
        local fitted = math.max(6, math.floor(size * font_s))
        local actual = nil
        local ok_measure, measured = pcall(function()
            local Font = require("ui/font")
            local TextWidget = require("ui/widget/textwidget")
            local widget = TextWidget:new{
                text=tostring(text or ""),
                face=Font:getFace(simpleUIFontFace(), fitted),
                fgcolor=color or BB.COLOR_BLACK,
            }
            local size_info = widget:getSize()
            widget:free()
            return size_info.w
        end)
        if ok_measure then actual = measured end
        if not actual then
            actual = 0
            for _, ch in ipairs(utf8Chars(tostring(text or ""))) do
                actual = actual + (ch:byte(1) >= 128 and fitted or fitted * .58)
            end
        end
        local box = math.floor(width_ref * s)
        drawText(bb, tostring(text or ""), X(left) + math.floor((box - actual) / 2), Y(top), fitted, bold, nil, color)
    end
    local function M(text, size, color)
        local fitted = math.max(6, math.floor(size * font_s))
        local actual = 0
        local ok_measure, measured = pcall(function()
            local Font = require("ui/font")
            local TextWidget = require("ui/widget/textwidget")
            local widget = TextWidget:new{text=tostring(text or ""), face=Font:getFace(simpleUIFontFace(), fitted), fgcolor=color or BB.COLOR_BLACK}
            local width = widget:getSize().w
            widget:free()
            return width
        end)
        if ok_measure then actual = measured else
            for _, ch in ipairs(utf8Chars(tostring(text or ""))) do actual = actual + (ch:byte(1) >= 128 and fitted or fitted * .58) end
        end
        return actual, fitted
    end
    local ink, muted, line = BB.COLOR_BLACK, BB.COLOR_GRAY_8, BB.COLOR_GRAY_C
    bb:paintRect(X(12), Y(8), math.max(1, X(994)-X(12)), math.max(1, Y(1084)-Y(8)), BB.COLOR_BLACK)
    bb:paintRect(X(18), Y(14), math.max(1, X(988)-X(18)), math.max(1, Y(1078)-Y(14)), BB.COLOR_WHITE)
    L(18,14,988,14,ink,2); L(18,14,18,1078,ink,2); L(988,14,988,1078,ink,2); L(18,1078,988,1078,ink,2)
    L(38,30,968,30,line,1); L(38,1062,968,1062,line,1); L(38,30,38,1062,line,1); L(968,30,968,1062,line,1)
    rlPaintTicketNotches(bb, X(18), Y(14), X(988)-X(18), Y(1078)-Y(14), math.max(12, math.floor(36*s)), BB.COLOR_WHITE,
        {top=true, bottom=true, left=true, right=true, notch_x=X(770), notch_y=Y(714)})
    T("阅读日票 · READING DAY PASS", 58, 67, 11, true, 420, ink)
    T("DAY TICKET", 58, 101, 42, true, 600, ink)
    T("今日阅读轨迹 / ONE DAY, FOUR BOARDINGS", 58, 177, 12, false, 560, muted)
    DL(53,235,952,235,line,1)
    T("日期 · DATE", 58, 246, 9, false, 120, muted); T(rlDate(start), 58, 266, 16, true, 150, ink)
    L(240,243,240,282,line,1)
    T("星期 · WEEKDAY", 270, 246, 9, false, 170, muted); T(cn_weekday .. " · " .. en_weekday, 270, 266, 16, true, 190, ink)
    -- Give the weekday block its full width before starting VALID.
    L(500,243,500,282,line,1)
    T("有效日期 · VALID", 540, 246, 9, false, 160, muted); T("当日有效", 540, 266, 16, true, 180, ink)
    DL(53,307,952,307,line,1)
    DL(770,31,770,235,line,1)
    -- The stub is a separate vertical column; lift the whole group clear of
    -- the horizontal rule below it.
    local gate_text = string.format("%02dA", weekday_index)
    local gate_width = M(gate_text, 28, ink)
    local a_width = M("A", 28, ink)
    local gate_right = X(796) + math.floor((130 * s + gate_width) / 2) + a_width
    local function RT(text, top, size, bold, color)
        local actual, fitted = M(text, size, color)
        drawText(bb, tostring(text or ""), gate_right - actual, Y(top), fitted, bold, nil, color)
    end
    RT("NO. D" .. os.date("%Y%m%d", start), 48, 10, false, muted)
    RT("检票口 · GATE", 75, 8, false, muted)
    RT(gate_text, 94, 28, true, ink)
    DL(795, 143, 952, 143, line, 1)
    RT("▼", 146, 10, true, ink)
    RT("日票", 169, 10, false, ink)
    RT("DAY PASS", 191, 10, false, ink)
    -- The web version leaves a deliberate lower band for summary + barcode.
    -- Keep the boarding rail compact instead of consuming that band.
    local top, bottom = 329, 630
    local line_x = 169
    L(line_x, top, line_x, bottom, ink, 2)
    local per_page = 7
    local total_boarding_pages = math.max(1, math.ceil(#boardings / per_page))
    local boarding_page = math.max(1, math.min(total_boarding_pages, tonumber(self.stats_boarding_page) or 1))
    self.stats_boarding_page = boarding_page
    local first_boarding = (boarding_page - 1) * per_page + 1
    local last_boarding = math.min(#boardings, first_boarding + per_page - 1)
    local max_rows = math.max(0, last_boarding - first_boarding + 1)
    if max_rows > 0 then
        for slot = 1, max_rows do
            local i = first_boarding + slot - 1
            local row = boardings[i]
            local cy = top + (slot - 1) * ((bottom - top) / math.max(1, max_rows - 1))
            if bb.paintCircle then
                if slot == max_rows then
                    local outer = math.max(8, math.floor(13*s))
                    pcall(bb.paintCircle, bb, X(line_x), Y(cy), outer, ink)
                    pcall(bb.paintCircle, bb, X(line_x), Y(cy), math.max(3, math.floor(7*s)), ink)
                else
                    local outer = math.max(7, math.floor(10*s))
                    pcall(bb.paintCircle, bb, X(line_x), Y(cy), outer, ink)
                    pcall(bb.paintCircle, bb, X(line_x), Y(cy), math.max(2, math.floor(7*s)), BB.COLOR_WHITE)
                end
            end
            T(os.date("%H:%M", row.time), 69, cy-6, 10, false, 70, muted)
            T("上车", 206, cy-8, 15, true, 64, ink)
            T("《" .. row.title .. "》", 294, cy-11, 16, true, 430, ink)
            T("第 " .. tostring(row.first_page or 0) .. " 页 · 当前阅读", 294, cy+15, 9, false, 380, muted)
            T(rlTime(row.duration), 876, cy-8, 14, false, 80, ink)
            self.stats_hit_books[#self.stats_hit_books + 1] = {x=X(270), y=Y(cy-20), w=math.floor(500*s), h=math.floor(38*s), title=row.title}
            self.stats_hit_records[#self.stats_hit_records + 1] = {
                x=X(55), y=Y(cy-24), w=math.floor(900*s), h=math.max(28, math.floor(44*s)), boarding=row,
            }
        end
    else
        T(ok and "当天没有阅读记录 · NO BOARDINGS" or "统计库暂不可用", 294, 505, 13, false, 400, muted)
    end
    L(53,706,952,706,line,1)
    T("今日摘要", 58, 737, 16, true, 130, ink); T("SUMMARY", 190, 742, 9, false, 100, muted)
    L(53,774,952,774,line,1)
    local longest = 0
    for _, row in ipairs(boardings) do longest = math.max(longest, row.duration or 0) end
    local summary = {
        {"READING TIME", "阅读时长", rlTime(agg.seconds), "19-vintage-timetable.svg"},
        {"PAGES READ", "阅读页数", tostring(agg.pages) .. " 页", "18-vintage-ticket.svg"},
        {"WORDS READ", "阅读字数", rlFormatWords(agg.words), "14-station-signboard.svg"},
        {"LONGEST READING", "最长阅读", rlTime(longest), "03-train-front.svg"},
    }
    local function Circle(cx, cy, radius, color)
        local r = math.max(2, math.floor(radius * ui_s))
        if bb.paintCircle then pcall(bb.paintCircle, bb, X(cx), Y(cy), r, color)
        else bb:paintRect(X(cx)-r, Y(cy)-r, r*2, r*2, color) end
    end
    local day_p = {X=X, Y=Y, L=L, T=T, CT=CT, Circle=Circle, s=s, sy=sy, ui_s=ui_s, font_s=font_s}
    rlReferenceMetrics(bb, day_p, summary, 789, 910)
    self.stats_duration_hit = {x=X(53), y=Y(789), w=math.floor(205*s), h=math.max(40, Y(910)-Y(789)), from_ts=start, to_ts=start+86400, label="今日阅读时长"}
    L(53,910,952,910,line,1)
    local caption = "阅读线路 · READING LINE · 日票 · DAY TICKET · D" .. os.date("%Y%m%d", start)
    rlReferenceFooter(self, bb, day_p, "D" .. tostring(start), caption, true)
end

function Shelf:paintReadingWeek(bb, x, y, w, h)
    self.stats_hit_books = {}
    local base = rlDayStart(self.stats_date)
    local monday = base - ((tonumber(os.date("%w", base)) or 0) - 1) * 86400
    if tonumber(os.date("%w", base)) == 0 then monday = base - 6 * 86400 end
    local rows, ok = self:readingRows(monday, monday + 7 * 86400)
    local p = rlReferencePainter(bb, y, h)
    rlReferenceFrame(bb, p, {top=false, bottom=false, radius=36})
    local week_no = tonumber(os.date("%V", monday)) or 1
    local _, _, gate_index = rlWeekday(base)
    local gate = string.format("%02dA", gate_index)
    p.T("阅读周票 · READING WEEK PASS", 58, 55, 12, true, 560, BB.COLOR_GRAY_8)
    p.T("WEEK TICKET", 58, 86, 48, true, 690, BB.COLOR_BLACK)
    -- Keep the subtitle below the large heading on both the 1272px KPW6 and
    -- the 1860px Scribe; its reference position is scaled at paint time.
    p.T("七日阅读路线 / SEVEN DAY LINE", 58, 164, 12, false, 560, BB.COLOR_GRAY_8)
    p.DL(790, 30, 790, 258, BB.COLOR_GRAY_8, 1)
    local gate_width = p.M(gate, 28, BB.COLOR_BLACK)
    local a_width = p.M("A", 28, BB.COLOR_BLACK)
    local gate_right = p.X(796) + math.floor((130 * p.s + gate_width) / 2) + a_width
    local function RT(text, top, size, bold, color)
        local actual, fitted = p.M(text, size, color)
        drawText(bb, tostring(text or ""), gate_right - actual, p.Y(top), fitted, bold, nil, color)
    end
    RT("NO. WT" .. os.date("%Y", monday) .. "-" .. string.format("%02d", week_no), 48, 10, false, BB.COLOR_GRAY_8)
    RT("检票口 · GATE", 75, 8, false, BB.COLOR_GRAY_8)
    RT(gate, 94, 28, true, BB.COLOR_BLACK)
    p.DL(795, 143, 952, 143, BB.COLOR_GRAY_C, 1)
    RT("▼", 146, 10, true, BB.COLOR_BLACK)
    RT("7 DAYS", 169, 10, false, BB.COLOR_BLACK)
    RT("WEEK PASS", 191, 10, false, BB.COLOR_GRAY_8)
    p.DL(53, 190, 760, 190, BB.COLOR_GRAY_C, 1)
    p.T("周次 · WEEK", 58, 206, 8, false, 120, BB.COLOR_GRAY_8)
    p.T("W" .. string.format("%02d", week_no), 58, 228, 16, true, 120, BB.COLOR_BLACK)
    p.L(205, 202, 205, 254, BB.COLOR_GRAY_C, 1)
    p.T("起止日期 · VALID", 236, 206, 8, false, 170, BB.COLOR_GRAY_8)
    p.T(rlDate(monday) .. " — " .. rlDate(monday + 6 * 86400), 236, 228, 15, true, 350, BB.COLOR_BLACK)
    p.L(625, 202, 625, 254, BB.COLOR_GRAY_C, 1)
    p.T("有效期 · VALID", 655, 206, 8, false, 100, BB.COLOR_GRAY_8)
    p.T("7 DAYS", 655, 228, 15, true, 100, BB.COLOR_BLACK)
    p.DL(53, 270, 952, 270, BB.COLOR_GRAY_8, 1)
    local line_y = 386
    p.L(68, line_y, 938, line_y, BB.COLOR_BLACK, 3)
    local total_seconds, active_days = 0, 0
    for d = 0, 6 do
        local day_start = monday + d * 86400
        local day_rows = {}
        for _, row in ipairs(rows) do if row.time >= day_start and row.time < day_start + 86400 then day_rows[#day_rows+1] = row end end
        local agg = rlAggregate(day_rows)
        total_seconds = total_seconds + agg.seconds
        if agg.sessions > 0 then active_days = active_days + 1 end
        local cx = 113 + d * 128
        local is_today = rlDayStart(os.time()) == day_start
        p.CT(os.date("%a", day_start):upper(), cx - 55, 307, 110, 10, true, BB.COLOR_BLACK)
        p.CT(rlDate(day_start):sub(6), cx - 55, 328, 110, 9, false, BB.COLOR_GRAY_8)
        p.CT(rlTime(agg.seconds), cx - 55, 347, 110, 10, true, BB.COLOR_BLACK)
        p.Circle(cx, line_y, is_today and 11 or 9, is_today and BB.COLOR_BLACK or BB.COLOR_WHITE)
        if not is_today then p.Circle(cx, line_y, 5, BB.COLOR_GRAY_8) end
        local branch_y, seen, book_count = line_y + 18, {}, 0
        for _, row in ipairs(rlBoardings(day_rows)) do
            if not seen[row.id] and book_count < 3 then
                seen[row.id] = true
                book_count = book_count + 1
                p.L(cx, branch_y, cx, branch_y + 25, BB.COLOR_GRAY_8, 1)
                p.CT("《" .. rlEllipsize(row.title, 8) .. "》", cx - 60, branch_y + 31, 120, 9, true, BB.COLOR_BLACK)
                p.CT("第 " .. tostring(row.first_page or 0) .. " 页", cx - 60, branch_y + 50, 120, 8, false, BB.COLOR_GRAY_8)
                self.stats_hit_books[#self.stats_hit_books + 1] = {x=p.X(cx-62), y=p.Y(branch_y+24), w=math.floor(124*p.s), h=math.floor(48*p.sy), title=row.title}
                branch_y = branch_y + 78
            end
        end
    end
    p.L(53, 736, 952, 736, BB.COLOR_GRAY_8, 1)
    p.T("本周", 58, 750, 16, true, 100, BB.COLOR_BLACK)
    p.T("WEEKLY", 120, 755, 9, false, 100, BB.COLOR_GRAY_8)
    p.L(53, 789, 952, 789, BB.COLOR_GRAY_C, 1)
    local week_agg = rlAggregate(rows)
    local summary = {
        {"READING TIME","阅读时长",rlTime(total_seconds),"19-vintage-timetable.svg"},
        {"ACTIVE DAYS","阅读天数",tostring(active_days),"18-vintage-ticket.svg"},
        {"FINISHED","读完数量",tostring(rlFinishedCount(rows)),"20-leather-luggage.svg"},
        {"PAGES READ","阅读页数",tostring(week_agg.pages),"14-station-signboard.svg"},
    }
    rlReferenceMetrics(bb, p, summary, 789, 910)
    self.stats_duration_hit = {x=p.X(53), y=p.Y(789), w=math.floor(205*p.s), h=math.max(40, p.Y(910)-p.Y(789)), from_ts=monday, to_ts=monday+7*86400, label="本周阅读时长"}
    p.L(53, 910, 952, 910, BB.COLOR_GRAY_C, 1)
    rlReferenceFooter(self, bb, p, "W" .. tostring(monday), "保持阅读 · KEEP READING · WEEK " .. string.format("%02d", week_no), true)
    if not ok then p.T("统计库暂不可用", 300, 690, 12, false, 400, BB.COLOR_GRAY_8) end
end

local function paintReadingMonthBody(self, bb, x, y, w, h)
    self.stats_hit_books = {}
    local current = os.date("*t", self.stats_date)
    local month_start = os.time{year=current.year, month=current.month, day=1, hour=0, min=0, sec=0}
    local days = os.date("%d", os.time{year=current.year, month=current.month + 1, day=0})
    days = tonumber(days) or 30
    local rows, ok = self:readingRows(month_start, os.time{year=current.year, month=current.month + 1, day=1, hour=0, min=0, sec=0})
    local calendar_books, calendar_ok = self:readingCalendarBooks(current.year, current.month)
    local by_day = rlAggregate(rows).days
    local p = rlReferencePainter(bb, y, h)
    rlReferenceFrame(bb, p, {left=false, right=false, notch_x=806, radius=36})
    local month_names = {"JAN.","FEB.","MAR.","APR.","MAY","JUN.","JUL.","AUG.","SEP.","OCT.","NOV.","DEC."}
    p.T("阅读线路 · READING LINE · 月度联票", 58, 50, 12, true, 500, BB.COLOR_GRAY_8)
    p.T("MONTH PASS", 58, 72, 48, true, 540, BB.COLOR_BLACK)
    p.T("NO. WT" .. string.format("%04d-%02d", current.year, current.month), 58, 141, 11, false, 250, BB.COLOR_GRAY_8)
    -- Keep the two-line year/month block to the right of MONTH PASS.  Its old
    -- x=610 position caused AUG. to print through the large title on Scribe.
    p.T(tostring(current.year), 690, 69, 20, true, 92, BB.COLOR_BLACK)
    p.T(month_names[current.month], 690, 105, 22, true, 94, BB.COLOR_BLACK)
    local now = os.date("*t")
    if now.year == current.year and now.month == current.month then
        p.T("CURRENT", 690, 43, 8, true, 86, BB.COLOR_GRAY_8)
    end
    p.DL(53, 188, 785, 188, BB.COLOR_GRAY_8, 1)
    p.DL(800, 30, 800, 770, BB.COLOR_GRAY_8, 1)
    local month_train_size = math.max(84, math.floor(120*p.ui_s))
    rlMetricIcon(bb, "03-train-front.svg", p.X(876) - math.floor(month_train_size/2), p.Y(34), month_train_size)
    p.CT("有效期 · VALID", 813, 170, 132, 10, false, BB.COLOR_GRAY_8)
    p.CT(string.format("%02d.%02d", current.month, 1), 813, 205, 132, 20, true, BB.COLOR_BLACK)
    p.DL(878, 239, 878, 260, BB.COLOR_GRAY_8, 1)
    p.CT(string.format("%02d.%02d", current.month, days), 813, 266, 132, 20, true, BB.COLOR_BLACK)
    local gx, gy, grid_right, grid_bottom = 53, 213, 785, 754
    local cell_w, cell_h = (grid_right - gx) / 7, (grid_bottom - (gy + 30)) / 6
    for col = 0, 6 do p.CT(({"MON","TUE","WED","THU","FRI","SAT","SUN"})[col+1], gx + col * cell_w, gy, cell_w, 10, true, BB.COLOR_BLACK) end
    p.L(gx, gy + 28, grid_right, gy + 28, BB.COLOR_GRAY_8, 1)
    for col = 0, 7 do p.L(gx + col*cell_w, gy + 28, gx + col*cell_w, grid_bottom, BB.COLOR_GRAY_C, 1) end
    for row = 0, 6 do p.L(gx, gy + 28 + row*cell_h, grid_right, gy + 28 + row*cell_h, BB.COLOR_GRAY_C, 1) end
    local first_wday = tonumber(os.date("%w", month_start)) or 0
    first_wday = (first_wday + 6) % 7
    for day = 1, days do
        local slot = first_wday + day - 1
        local col, row = slot % 7, math.floor(slot / 7)
        local cx, cy = gx + col * cell_w, gy + 28 + row * cell_h
        p.T(tostring(day), cx + 6, cy + 5, 11, true, cell_w - 12, BB.COLOR_BLACK)
    end
    local calendar_weeks = rlCalendarWeeks(current.year, current.month, days, first_wday, calendar_books, 3)
    local span_colors = {
        {fg=BB.COLOR_WHITE, bg=BB.COLOR_GRAY_4},
        {fg=BB.COLOR_WHITE, bg=BB.COLOR_GRAY_8},
        {fg=BB.COLOR_WHITE, bg=BB.COLOR_GRAY_4},
        {fg=BB.COLOR_WHITE, bg=BB.COLOR_GRAY_4},
    }
    for week_index, week in ipairs(calendar_weeks) do
        for col, day_books in ipairs(week.days_books) do
            for lane, book in ipairs(day_books) do
                if book and book.start_day == col then
                    local color = span_colors[(book.id % #span_colors) + 1]
                    local sx = gx + (col - 1) * cell_w + 4
                    local sy = gy + 28 + (week_index - 1) * cell_h + 29 + (lane - 1) * 19
                    local span_w = book.span_days * cell_w - 8
                    p.R(sx, sy, span_w, 16, color.bg)
                    local max_chars = math.max(3, math.floor((span_w - 8) / 10))
                    p.CT(rlEllipsize(book.title, max_chars), sx, sy + 2, span_w, 7, true, color.fg)
                    self.stats_hit_books[#self.stats_hit_books + 1] = {
                        x=p.X(sx), y=p.Y(sy), w=math.floor(span_w*p.s), h=math.floor(19*p.sy), title=book.title,
                    }
                end
            end
        end
    end
    local month_agg = rlAggregate(rows)
    local active = 0; for _ in pairs(by_day) do active = active + 1 end
    p.L(53, 789, 952, 789, BB.COLOR_GRAY_8, 1)
    local summary = {
        {"READING TIME","阅读时长",rlTime(month_agg.seconds),"19-vintage-timetable.svg"},
        {"READING DAYS","阅读天数",tostring(active),"18-vintage-ticket.svg"},
        {"FINISHED","读完数量",tostring(rlFinishedCount(rows)),"20-leather-luggage.svg"},
        {"PAGES READ","阅读页数",tostring(month_agg.pages),"14-station-signboard.svg"},
    }
    rlReferenceMetrics(bb, p, summary, 789, 910)
    self.stats_duration_hit = {x=p.X(53), y=p.Y(789), w=math.floor(205*p.s), h=math.max(40, p.Y(910)-p.Y(789)), from_ts=month_start, to_ts=os.time{year=current.year, month=current.month+1, day=1, hour=0, min=0, sec=0}, label="本月阅读时长"}
    p.L(53, 910, 952, 910, BB.COLOR_GRAY_C, 1)
    rlReferenceFooter(self, bb, p, string.format("M%04d%02d", current.year, current.month), string.format("阅读线路 · READING LINE · MONTH PASS · %04d.%02d", current.year, current.month), true)
    if not ok or not calendar_ok then p.T("统计库暂不可用", 300, 730, 12, false, 400, BB.COLOR_GRAY_8) end
end

function Shelf:paintReadingMonth(bb, x, y, w, h)
    local ok, err = xpcall(function()
        paintReadingMonthBody(self, bb, x, y, w, h)
    end, debug.traceback)
    if ok then return end
    logger.warn("simplebookshelf: month ticket paint failed", err)
    self.stats_hit_books = {}
    local p = rlReferencePainter(bb, y, h)
    rlReferenceFrame(bb, p, {left=false, right=false, radius=36})
    p.T("阅读线路 · READING LINE · 月度联票", 58, 50, 12, true, 500, BB.COLOR_GRAY_8)
    p.T("MONTH PASS", 58, 72, 48, true, 560, BB.COLOR_BLACK)
    p.DL(53, 188, 952, 188, BB.COLOR_GRAY_8, 1)
    p.T("月票数据绘制失败", 300, 455, 18, true, 420, BB.COLOR_BLACK)
    p.T("已拦截异常记录，插件不会退出", 300, 493, 11, false, 420, BB.COLOR_GRAY_8)
end

function Shelf:paintReadingYear(bb, x, y, w, h)
    local year = os.date("*t", self.stats_date).year
    local year_start = os.time{year=year, month=1, day=1, hour=0, min=0, sec=0}
    local rows, ok = self:readingRows(year_start, os.time{year=year+1, month=1, day=1, hour=0, min=0, sec=0})
    local p = rlReferencePainter(bb, y, h)
    rlReferenceFrame(bb, p, {left=false, right=false, radius=36})
    p.T("阅读线路 · READING LINE · 年度联票", 58, 50, 12, true, 570, BB.COLOR_GRAY_8)
    p.T("YEAR PASS", 58, 82, 48, true, 600, BB.COLOR_BLACK)
    p.T(string.format("%04d · TWELVE MONTHS OF READING", year), 58, 162, 12, false, 560, BB.COLOR_GRAY_8)
    p.L(790, 30, 790, 190, BB.COLOR_GRAY_8, 1)
    p.CT("有效期 · VALID", 810, 56, 138, 10, false, BB.COLOR_GRAY_8)
    p.CT("01.01", 810, 92, 138, 18, true, BB.COLOR_BLACK)
    p.L(878, 132, 878, 150, BB.COLOR_GRAY_8, 1)
    p.CT("12.31", 810, 158, 138, 18, true, BB.COLOR_BLACK)
    p.DL(53, 194, 952, 194, BB.COLOR_GRAY_8, 1)
    local month_data, max_seconds = {}, 0
    for month = 1, 12 do
        local from = os.time{year=year, month=month, day=1, hour=0, min=0, sec=0}
        local to = os.time{year=year, month=month+1, day=1, hour=0, min=0, sec=0}
        local month_rows, days, books = {}, {}, {}
        for _, row in ipairs(rows) do
            if row.time >= from and row.time < to then
                month_rows[#month_rows+1] = row
                days[os.date("%Y-%m-%d", row.time)] = true
                books[row.title] = true
            end
        end
        local agg = rlAggregate(month_rows)
        local day_count, book_count = 0, 0
        for _ in pairs(days) do day_count=day_count+1 end
        for _ in pairs(books) do book_count=book_count+1 end
        month_data[month] = {rows=month_rows, seconds=agg.seconds, days=day_count, books=book_count, finished=rlFinishedCount(month_rows)}
        max_seconds = math.max(max_seconds, agg.seconds)
    end
    local month_names = {"JAN.","FEB.","MAR.","APR.","MAY","JUN.","JUL.","AUG.","SEP.","OCT.","NOV.","DEC."}
    local now = os.date("*t")
    local cell_w, cell_h, gap_x, gap_y = 286, 126, 12, 11
    for month = 1, 12 do
        local data = month_data[month]
        local index = month - 1
        local cx = 54 + (index % 3) * (cell_w + gap_x)
        local cy = 207 + math.floor(index / 3) * (cell_h + gap_y)
        local current = now.year == year and now.month == month
        local future = year > now.year or (year == now.year and month > now.month)
        local ink = future and BB.COLOR_GRAY_C or BB.COLOR_BLACK
        p.R(cx, cy, cell_w, cell_h, current and BB.COLOR_GRAY_E or BB.COLOR_WHITE)
        p.L(cx, cy, cx+cell_w, cy, BB.COLOR_GRAY_8, 1)
        p.L(cx, cy+cell_h, cx+cell_w, cy+cell_h, BB.COLOR_GRAY_8, 1)
        p.L(cx, cy, cx, cy+cell_h, BB.COLOR_GRAY_C, 1)
        p.L(cx+cell_w, cy, cx+cell_w, cy+cell_h, BB.COLOR_GRAY_C, 1)
        p.T(string.format("%02d", month), cx+12, cy+9, 20, true, 45, ink)
        p.T(month_names[month], cx+61, cy+13, 10, true, 65, ink)
        local intensity = max_seconds > 0 and data.seconds / max_seconds or 0
        local blocks = math.ceil(intensity * 8)
        for i=1,8 do
            local shade = i <= blocks and (intensity > .66 and BB.COLOR_GRAY_4 or intensity > .33 and BB.COLOR_GRAY_8 or BB.COLOR_GRAY_C) or BB.COLOR_GRAY_E
            p.R(cx+13+(i-1)*23, cy+49, 18, 11, shade)
        end
        p.DL(cx+10, cy+67, cx+cell_w-10, cy+67, BB.COLOR_GRAY_C, 1)
        p.T(tostring(data.days) .. " DAYS", cx+13, cy+75, 9, false, 76, ink)
        p.T(rlTime(data.seconds), cx+101, cy+75, 10, true, 84, ink)
        p.T(tostring(data.books) .. " BOOKS", cx+13, cy+98, 9, false, 90, ink)
        p.T(tostring(data.finished) .. " FINISHED", cx+101, cy+98, 9, false, 104, ink)
        for i=1, math.min(6, data.finished) do
            p.Circle(cx+cell_w-18, cy+18+(i-1)*17, 4, future and BB.COLOR_GRAY_C or BB.COLOR_GRAY_8)
        end
    end
    local all = rlAggregate(rows)
    p.L(53, 789, 952, 789, BB.COLOR_GRAY_8, 1)
    local summary = {
        {"READING TIME","阅读时长",rlTime(all.seconds),"19-vintage-timetable.svg"},
        {"ACTIVE DAYS","阅读天数",tostring((function() local n=0; for _ in pairs(all.days) do n=n+1 end; return n end)()),"18-vintage-ticket.svg"},
        {"FINISHED","读完数量",tostring(rlFinishedCount(rows)),"20-leather-luggage.svg"},
        {"WORDS READ","累计字数",rlFormatWords(all.words),"14-station-signboard.svg"},
    }
    rlReferenceMetrics(bb, p, summary, 789, 910)
    self.stats_duration_hit = {x=p.X(53), y=p.Y(789), w=math.floor(205*p.s), h=math.max(40, p.Y(910)-p.Y(789)), from_ts=year_start, to_ts=os.time{year=year+1, month=1, day=1, hour=0, min=0, sec=0}, label="年度阅读时长"}
    p.L(53, 910, 952, 910, BB.COLOR_GRAY_C, 1)
    rlReferenceFooter(self, bb, p, "Y" .. tostring(year), "阅读线路 · Y" .. tostring(year) .. "-001-READING-LINE", true)
    if not ok then p.T("统计库暂不可用", 300, 740, 12, false, 400, BB.COLOR_GRAY_8) end
end

function Shelf:paintReadingBook(bb, x, y, w, h)
    local rows, ok = self:readingRows(0, os.time() + 1)
    local latest = rows[#rows]
    local title = self.stats_selected_book or (latest and latest.title) or "暂无阅读记录"
    local selected = {}
    for _, row in ipairs(rows) do if row.title == title then selected[#selected+1] = row end end
    local first, last = selected[1], selected[#selected]
    local journeys = rlBoardings(selected)
    local aggregate = rlAggregate(selected)
    local seconds = aggregate.seconds
    local longest_pause = 0
    for i = 2, #journeys do
        local previous_end = (journeys[i-1].last_time or journeys[i-1].time or 0) + (journeys[i-1].duration or 0)
        longest_pause = math.max(longest_pause, math.max(0, (journeys[i].time or 0) - previous_end))
    end
    local average = #journeys > 0 and seconds / #journeys or 0
    local total_pages = 0
    for _, row in ipairs(selected) do total_pages = math.max(total_pages, tonumber(row.pages) or 0) end
    local current_page = tonumber(last and (last.display_page or last.page)) or 0
    local progress = total_pages > 0 and math.max(0, math.min(100, math.floor(current_page * 100 / total_pages + .5))) or 0
    local author = tostring(first and first.authors or "")
    if author == "" then author = "作者信息未记录" end
    local first_date = first and os.date("%m.%d", first.time) or "--.--"
    local stamp_date = first and os.date("*t", first.time) or os.date("*t", self.stats_date or os.time())
    local month_names = {"JAN.","FEB.","MAR.","APR.","MAY","JUN.","JUL.","AUG.","SEP.","OCT.","NOV.","DEC."}
    local p = rlReferencePainter(bb, y, h)
    rlReferenceFrame(bb, p, {radius=36})

    -- Ticket identity and centered title block.
    p.T("TICKET NO.", 68, 52, 9, false, 160, BB.COLOR_GRAY_8)
    p.T(string.format("%02d%04d-%d", stamp_date.month, stamp_date.year, tonumber(first and first.id) or 1), 68, 72, 17, true, 220, BB.COLOR_BLACK)
    p.CT(string.format("%04d / %s", stamp_date.year, month_names[stamp_date.month]), 724, 52, 220, 11, true, BB.COLOR_BLACK)
    p.CT("BOOK JOURNEY", 205, 94, 600, 40, true, BB.COLOR_BLACK)
    p.L(212, 184, 330, 184, BB.COLOR_GRAY_8, 1)
    p.L(676, 184, 794, 184, BB.COLOR_GRAY_8, 1)
    p.CT("单 书 行 程 票", 340, 169, 326, 16, true, BB.COLOR_BLACK)
    p.DL(68, 198, 938, 198, BB.COLOR_GRAY_C, 1)

    -- Main book card.
    p.R(68, 207, 870, 229, BB.COLOR_WHITE)
    p.L(68, 207, 938, 207, BB.COLOR_GRAY_8, 1); p.L(68, 436, 938, 436, BB.COLOR_GRAY_8, 1)
    p.L(68, 207, 68, 436, BB.COLOR_GRAY_C, 1); p.L(938, 207, 938, 436, BB.COLOR_GRAY_C, 1)
    p.R(91, 231, 148, 125, BB.COLOR_GRAY_E)
    p.L(91,231,239,231,BB.COLOR_GRAY_8,1); p.L(91,356,239,356,BB.COLOR_GRAY_8,1)
    p.L(91,231,91,356,BB.COLOR_GRAY_8,1); p.L(239,231,239,356,BB.COLOR_GRAY_8,1)
    local library_book
    for _, book in ipairs(self.books or {}) do
        if tostring(book.title or "") == title then library_book = book; break end
    end
    local cover_painted = false
    if library_book then
        local cover_w, cover_h = math.max(1, math.floor(148*p.s)), math.max(1, math.floor(125*p.sy))
        local cover = getBookCoverWidget(library_book.path, cover_w, cover_h, "center")
        if cover then
            paintTopRoundedWidget(cover, bb, p.X(91), p.Y(231), cover_w, cover_h, 0)
            if cover.free then cover:free() end
            cover_painted = true
        end
    end
    if not cover_painted then
        local cover_chars = utf8Chars(title)
        for i = 1, math.min(5, #cover_chars) do p.T(cover_chars[i], 108, 239 + (i-1)*20, 12, true, 34, BB.COLOR_BLACK) end
    end
    p.T("《" .. title .. "》", 271, 244, 21, true, 445, BB.COLOR_BLACK)
    p.T(author .. " · BOARDING DATE " .. first_date, 271, 282, 10, false, 445, BB.COLOR_GRAY_8)
    p.T("当前进度", 776, 238, 9, false, 125, BB.COLOR_GRAY_8)
    p.T(tostring(progress) .. "%", 776, 263, 29, true, 125, BB.COLOR_BLACK)
    p.R(776, 311, 118, 7, BB.COLOR_GRAY_E)
    if progress > 0 then p.R(776, 311, math.max(2, 118 * progress / 100), 7, BB.COLOR_GRAY_4) end
    p.T(tostring(current_page) .. " / " .. tostring(total_pages > 0 and total_pages or "—") .. " 页", 776, 326, 9, false, 125, BB.COLOR_GRAY_8)
    local facts = {
        {"BOARDING DATE","出发日期",first_date},
        {"READING TIME","阅读时长",rlTime(seconds)},
        {"VISITS","阅读次数",tostring(#journeys)},
        {"AVG. VISIT","平均单次",rlTime(average)},
    }
    for i, item in ipairs(facts) do
        local cx = 91 + (i-1)*201
        if i > 1 then p.L(cx-13, 368, cx-13, 425, BB.COLOR_GRAY_C, 1) end
        p.T(item[1], cx, 368, 7, false, 170, BB.COLOR_GRAY_8)
        p.T(item[2], cx, 383, 8, false, 170, BB.COLOR_GRAY_8)
        p.T(item[3], cx, 404, 15, true, 170, BB.COLOR_BLACK)
        if i == 2 then p.T("↗", cx+157, 370, 8, true, 18, BB.COLOR_GRAY_8) end
    end
    self.stats_duration_hit = {x=p.X(279), y=p.Y(360), w=math.floor(188*p.s), h=math.max(35, p.Y(432)-p.Y(360)), from_ts=0, to_ts=os.time()+1, book_title=title, label="单书阅读时长"}

    -- Journey progress ruler and real reading milestones.
    p.T("0%", 68, 463, 10, true, 55, BB.COLOR_BLACK)
    p.CT(tostring(progress) .. "%", 770, 463, 90, 10, true, BB.COLOR_BLACK)
    p.T("100%", 884, 463, 10, true, 65, BB.COLOR_BLACK)
    p.L(87, 490, 918, 490, BB.COLOR_GRAY_8, 1)
    if progress > 0 then
        local progress_x = 87 + 831 * progress / 100
        p.Circle(progress_x, 490, 5, BB.COLOR_GRAY_4)
    end
    local milestone_count = math.min(7, #journeys)
    local milestones = {}
    if milestone_count == 1 then milestones[1] = journeys[1]
    elseif milestone_count > 1 then
        local used = {}
        for i = 1, milestone_count do
            local index = math.floor(1 + (i-1) * (#journeys-1) / (milestone_count-1) + .5)
            if not used[index] then used[index] = true; milestones[#milestones+1] = journeys[index] end
        end
    end
    local line_x, route_top, route_bottom = 88, 530, 865
    p.L(line_x, route_top, line_x, route_bottom, BB.COLOR_BLACK, 2)
    if #milestones == 0 then
        p.Circle(line_x, 595, 8, BB.COLOR_WHITE); p.Circle(line_x, 595, 4, BB.COLOR_GRAY_8)
        p.T(ok and "尚未开始阅读 · NO JOURNEY YET" or "统计库暂不可用", 132, 584, 13, false, 650, BB.COLOR_GRAY_8)
    else
        for i, journey in ipairs(milestones) do
            local cy = route_top + (i-1) * (route_bottom-route_top) / math.max(1, #milestones-1)
            local is_last = i == #milestones
            p.Circle(line_x, cy, is_last and 9 or 8, is_last and BB.COLOR_BLACK or BB.COLOR_WHITE)
            if not is_last then p.Circle(line_x, cy, 4, BB.COLOR_GRAY_8) end
            local row_page = tonumber(journey.last_page or journey.first_page) or 0
            local row_progress = total_pages > 0 and math.max(0, math.min(100, math.floor(row_page*100/total_pages+.5))) or 0
            p.T(os.date("%m.%d", journey.time), 128, cy-10, 10, true, 72, BB.COLOR_BLACK)
            p.T(tostring(row_progress) .. "%", 225, cy-10, 10, false, 62, BB.COLOR_GRAY_8)
            local label
            if i == 1 then label = "起点 · 首次登车"
            elseif is_last then label = "当前位置 · 第 " .. tostring(row_page) .. " 页"
            else label = "阅读打卡 · 第 " .. tostring(row_page) .. " 页" end
            p.T(label, 310, cy-11, 12, is_last, 410, BB.COLOR_BLACK)
            p.T(rlTime(journey.duration), 724, cy-9, 9, false, 80, BB.COLOR_GRAY_8)
            local badge = i == 1 and "首次登车" or (is_last and "当前停留" or "打卡")
            p.R(824, cy-14, 92, 27, is_last and BB.COLOR_GRAY_4 or BB.COLOR_WHITE)
            p.L(824,cy-14,916,cy-14,BB.COLOR_GRAY_8,1); p.L(824,cy+13,916,cy+13,BB.COLOR_GRAY_8,1)
            p.L(824,cy-14,824,cy+13,BB.COLOR_GRAY_8,1); p.L(916,cy-14,916,cy+13,BB.COLOR_GRAY_8,1)
            p.CT(badge, 824, cy-9, 92, 8, false, is_last and BB.COLOR_WHITE or BB.COLOR_BLACK)
        end
    end
    p.L(68, 902, 938, 902, BB.COLOR_GRAY_8, 1)
    p.T("最长搁置 " .. rlTime(longest_pause) .. " · 累计 " .. rlFormatWords(aggregate.words), 70, 918, 10, false, 490, BB.COLOR_GRAY_8)
    p.T("阅读不是终点，思考才是抵达。", 70, 953, 11, true, 420, BB.COLOR_BLACK)
    p.T("KEEP READING, KEEP GOING.  →", 684, 953, 10, false, 255, BB.COLOR_GRAY_8)
    self.stats_barcode_hit = nil
    self.stats_nav_hit = {dots={}}
end

function Shelf:paintReadingScreen(bb, x, y, w, h)
    local now = os.date("*t")
    local month_start = os.time{year=now.year, month=now.month, day=1, hour=0, min=0, sec=0}
    local rows = self:readingRows(month_start, os.time{year=now.year, month=now.month+1, day=1, hour=0, min=0, sec=0})
    local latest = rows[#rows]
    if not latest then
        local all_rows = self:readingRows(0, os.time() + 1)
        latest = all_rows[#all_rows]
    end
    local month = string.format("%04d.%02d", now.year, now.month)
    local privacy = store:readSetting("reading_line_privacy") == true
    local show_title = store:readSetting("reading_line_show_title") ~= false
    local show_node = store:readSetting("reading_line_show_node") ~= false
    local p = rlReferencePainter(bb, y, h)
    p.R(12, 8, 982, 1070, BB.COLOR_BLACK)
    p.R(18, 14, 970, 1064, BB.COLOR_GRAY_E)
    -- Keep the gray paper margin equal on all sides: 24 reference pixels on
    -- the left/right and top, with only the outer perforated edge visible.
    p.R(42, 38, 922, 1012, BB.COLOR_WHITE)
    p.L(18, 14, 18, 1078, BB.COLOR_BLACK, 2)
    p.L(988, 14, 988, 1078, BB.COLOR_BLACK, 2)
    p.L(18, 1078, 988, 1078, BB.COLOR_BLACK, 2)
    rlPaintTicketNotches(bb, p.X(18), p.Y(14), p.X(988)-p.X(18), p.Y(1078)-p.Y(14), math.max(8, math.floor(14*p.s)), BB.COLOR_GRAY_E,
        {stamp=true})
    -- Center the large title from its actual KOReader font width.  The two
    -- small labels share the title's measured left/right edges, so neither
    -- one is aligned against an unrelated frame coordinate.
    local title_text = "READING SCREEN"
    local title_width, title_font = p.M(title_text, 46, BB.COLOR_BLACK)
    local title_center = p.X(503)
    local title_left = title_center - math.floor(title_width / 2)
    local title_right = title_center + math.floor(title_width / 2)
    p.T("READING LINE", 503 - title_width / (2 * p.s), 82, 12, false, nil, BB.COLOR_GRAY_8)
    local number_text = "NO. WT" .. string.format("%04d-%02d", now.year, now.month)
    local number_width = p.M(number_text, 12, BB.COLOR_GRAY_8)
    p.T(number_text, 503 + title_width / (2 * p.s) - number_width / p.s, 82, 12, false, nil, BB.COLOR_GRAY_8)
    drawText(bb, title_text, title_left, p.Y(111), title_font, true, nil, BB.COLOR_BLACK)
    p.CT("阅读车票", 303, 196, 400, 18, true, BB.COLOR_BLACK)
    p.T(latest and (show_title and not privacy and ("当前阅读 · 《" .. latest.title .. "》") or "当前阅读 · 隐私模式") or "当前没有阅读记录", 112, 233, 15, true, 760, BB.COLOR_BLACK)
    local screen_agg = rlAggregate(rows)
    local stops, seen = {}, {}
    for i = #rows, 1, -1 do
        local row = rows[i]
        if not seen[row.id] then
            seen[row.id] = true
            stops[#stops + 1] = row
            if #stops >= 5 then break end
        end
    end
    local first_date = rows[1] and rlDate(rows[1].time):sub(6) or string.format("%02d.01", now.month)
    local current_date = string.format("%02d.%02d", now.month, now.day)
    local last_day = tonumber(os.date("%d", os.time{year=now.year, month=now.month+1, day=0})) or 30
    p.R(112, 310, 190, 372, BB.COLOR_WHITE)
    p.L(112, 310, 302, 310, BB.COLOR_GRAY_8, 1)
    p.L(112, 434, 302, 434, BB.COLOR_GRAY_C, 1)
    p.L(112, 558, 302, 558, BB.COLOR_GRAY_C, 1)
    p.L(112, 682, 302, 682, BB.COLOR_GRAY_8, 1)
    p.L(112, 310, 112, 682, BB.COLOR_GRAY_C, 1)
    p.L(302, 310, 302, 682, BB.COLOR_GRAY_C, 1)
    p.T("出发 · DEPART", 130, 334, 9, false, 150, BB.COLOR_GRAY_8)
    p.T(first_date, 130, 369, 22, true, 150, BB.COLOR_BLACK)
    p.T("当前 · CURRENT", 130, 458, 9, false, 150, BB.COLOR_GRAY_8)
    p.T(current_date, 130, 493, 22, true, 150, BB.COLOR_BLACK)
    p.T("终点 · DESTINATION", 130, 582, 9, false, 150, BB.COLOR_GRAY_8)
    p.T(string.format("%02d.%02d", now.month, last_day), 130, 617, 22, true, 150, BB.COLOR_BLACK)
    -- Align the route module with the top edge of the adjacent three-cell
    -- date block. Keep its height while moving the complete module down.
    local route_top, route_bottom, route_x = 310, 685, 420
    if #stops > 0 then
        p.L(route_x, route_top, route_x, route_bottom, BB.COLOR_BLACK, 2)
        for i, row in ipairs(stops) do
            local cy = route_top + math.floor((i - 1) * (route_bottom - route_top) / math.max(1, #stops - 1))
            p.Circle(route_x, cy, i == 1 and 11 or 8, i == 1 and BB.COLOR_BLACK or BB.COLOR_WHITE)
            if i ~= 1 then p.Circle(route_x, cy, 4, BB.COLOR_GRAY_8) end
            local label = (show_title and not privacy and ("《" .. row.title .. "》") or "隐私阅读节点")
            p.T(label, route_x + 32, cy - 13, 13, true, 430, BB.COLOR_BLACK)
            p.T((show_node and not privacy and ("第 " .. tostring(row.display_page or row.page or 0) .. " 页") or "阅读节点") .. " · " .. rlTime(row.duration), route_x + 32, cy + 12, 9, false, 430, BB.COLOR_GRAY_8)
        end
    else
        p.T("本月尚无阅读路线", 460, 460, 14, false, 360, BB.COLOR_GRAY_8)
    end
    p.DL(106, 208, 410, 208, BB.COLOR_GRAY_8, 1)
    p.DL(595, 208, 900, 208, BB.COLOR_GRAY_8, 1)
    p.DL(53, 789, 952, 789, BB.COLOR_GRAY_8, 1)
    local active_days = 0; for _ in pairs(screen_agg.days) do active_days=active_days+1 end
    local summary = {
        {"READING TIME","阅读时长",rlTime(screen_agg.seconds),"19-vintage-timetable.svg"},
        {"PAGES READ","阅读页数",tostring(screen_agg.pages),"18-vintage-ticket.svg"},
        {"BOOKS","阅读书籍",tostring((function() local n=0; for _ in pairs(screen_agg.books) do n=n+1 end; return n end)()),"20-leather-luggage.svg"},
        {"ACTIVE DAYS","阅读天数",tostring(active_days),"14-station-signboard.svg"},
    }
    rlReferenceMetrics(bb, p, summary, 789, 910)
    self.stats_duration_hit = {x=p.X(53), y=p.Y(789), w=math.floor(205*p.s), h=math.max(40, p.Y(910)-p.Y(789)), from_ts=month_start, to_ts=os.time{year=now.year, month=now.month+1, day=1, hour=0, min=0, sec=0}, label="本月阅读时长"}
    p.L(53, 910, 952, 910, BB.COLOR_GRAY_C, 1)
    rlReferenceFooter(self, bb, p, "S" .. month, "KEEP READING, KEEP GOING.", true)
end

-- Front-facing display cabinet.  This is intentionally not a variation of
-- the spine bookshelf: books are laid out as cover cards on horizontal
-- shelves, with a narrow side plane and contact shadow to suggest perspective.
function Shelf:paintShowcase(bb, x, y, width, height)
    local perf_started = os.clock()
    self.hit_books = {}
    local rows = math.max(2, math.min(6, tonumber(showcaseSetting("rows")) or 5))
    local gap = math.max(2, math.min(36, tonumber(showcaseSetting("book_gap")) or 10))
    local shelf_depth = math.max(0, math.min(8, tonumber(showcaseSetting("shelf_depth")) or tonumber(showcaseSetting("depth")) or 3))
    local shelf_thickness = math.max(3, math.min(18, tonumber(showcaseSetting("shelf_thickness")) or 8))
    local scale = math.max(70, math.min(180, tonumber(showcaseSetting("book_scale")) or 100)) / 100
    local margin_left = math.max(8, tonumber(showcaseSetting("margin_left")) or 48)
    local margin_right = math.max(8, tonumber(showcaseSetting("margin_right")) or 48)
    local cabinet_left, cabinet_right = 12, 12
    local row_h = math.floor(height / rows)
    -- The wallpaper is the cabinet background.  Do not paint a large white
    -- rectangle over it: each row gets one horizontal rear rail below,
    -- behind the covers and in front of the wallpaper, like the reference
    -- display cabinet.
    -- The former hanging plaque and the separate classification layer were
    -- removed; the display cabinet always presents the complete collection.
    self.plaque_hit = nil

    local filter = self:getShowcaseFilter()
    if not self.showcase_pages then self:buildShowcasePages() end
    local visible_books = self.showcase_pages[self.page] or {}
    if #visible_books == 0 then
        drawCenteredText(bb, "陈列架暂无书籍", x, y + math.floor(height * .45), 18, false, width, BB.COLOR_GRAY_8)
    end
    local index = 1
    for row = 1, rows do
        local shelf_y = y + row * row_h - shelf_thickness - 6
        -- Restore the original base-board gray. The rear rail is exactly one
        -- 16-level e-ink step darker, rather than falling back to black.
        bb:paintRect(x + cabinet_left, shelf_y, width - cabinet_left - cabinet_right, shelf_thickness, BB.COLOR_GRAY_4)
        bb:paintRect(x + cabinet_left, shelf_y, width - cabinet_left - cabinet_right, 2, BB.COLOR_GRAY_5)
        if shelf_depth > 0 then
            bb:paintRect(x + cabinet_left + 2, shelf_y + shelf_thickness, width - cabinet_left - cabinet_right - 4, shelf_depth, BB.COLOR_GRAY_3)
        end
        paintShowcaseSeamHighlight(bb, x + cabinet_left + 2, shelf_y + shelf_thickness,
            width - cabinet_left - cabinet_right - 4)
        local cursor = x + 24
        local row_bottom = shelf_y - 6
        -- A broad horizontal back rail sits behind the books, in front of
        -- the wallpaper, like the reference cabinet's rear mounting strip.
        -- Keep the bottom edge at one fixed distance above this row's base.
        -- The rail is deliberately about three base-board thicknesses wide
        -- and its center sits at the books' waist.
        local back_thickness = shelf_thickness * 3
        local back_bottom = row_bottom - math.floor(row_h * .33)
        local back_y = back_bottom - back_thickness
        local back_depth = math.max(3, math.floor(shelf_thickness * .55) + shelf_depth)
        bb:paintRect(x + cabinet_left, back_y, width - cabinet_left - cabinet_right,
            back_thickness, BB.COLOR_GRAY_3)
        bb:paintRect(x + cabinet_left, back_y, width - cabinet_left - cabinet_right, 2, BB.COLOR_GRAY_4)
        -- The lower edge is a separate extrusion, so the rear panel reads as
        -- a board with thickness instead of a flat gray stripe.
        bb:paintRect(x + cabinet_left + 2, back_y + back_thickness,
            width - cabinet_left - cabinet_right - 4, back_depth, BB.COLOR_GRAY_2)
        bb:paintRect(x + cabinet_left + 4, back_y + back_thickness + back_depth,
            width - cabinet_left - cabinet_right - 8, 2, BB.COLOR_GRAY_3)
        paintShowcaseSeamHighlight(bb, x + cabinet_left + 2, back_y + back_thickness,
            width - cabinet_left - cabinet_right - 4)
        cursor = x + margin_left
        while index <= #visible_books do
            local book = visible_books[index]
            -- Covers occupy roughly two thirds of the compartment, matching
            -- the reference cabinet rather than the tiny previous cards.
            local w, h = showcaseBookDimensions(book, row_h, scale)
            local lean, depth, depth_level = showcaseBookProjection(h)
            local projected_w = w + lean + depth
            if cursor + projected_w > x + width - margin_right then break end
            local bx, by = cursor, row_bottom - h
            local side_drop = math.max(2, math.min(8, math.floor(depth * .45 + .5)))
            local outer_x = paintSkewedBookFace(bb, bx, by, w, h, lean, depth, depth_level, side_drop)
            for row_y = 0, h - 1 do
                local shift = h <= 1 and lean or math.floor(lean * (h - 1 - row_y) / (h - 1) + .5)
                bb:paintRect(bx + shift, by + row_y, w, 1, BB.COLOR_GRAY_D)
            end
            -- Showcase deliberately uses the book's default front cover. It
            -- must not inherit the bookshelf's custom-spine image or any
            -- spine-fit setting: those belong only to the bookshelf tab.
            local cover
            local cover_path = tostring(book.path or ""):gsub("^file://", "")
            local cover_key = coverCacheKey(cover_path, math.max(1, w), math.max(1, h))
            -- Match the bookshelf's fast first paint: try the in-memory and
            -- persisted thumbnail caches immediately, then fill only misses
            -- in the background one cover at a time.
            cover = getBookCoverWidget(cover_path, math.max(1, w), math.max(1, h), "center", true)
            if not cover and cover_load_state[cover_key] ~= "missing" then
                queueShowcaseCoverLoad(self, cover_path, math.max(1, w), math.max(1, h),
                    Geom:new{x=bx - 2, y=by - 2, w=projected_w + 4, h=h + 8})
            end
            if cover then
                paintSkewedWidget(cover, bb, bx, by, math.max(1, w), math.max(1, h), lean)
                if cover.free then cover:free() end
            else
                drawText(bb, book.title or "", bx + lean + 5, by + math.floor(h * .38), 12, true, w - 10)
            end
            bb:paintRect(bx + lean, by, w, 2, BB.COLOR_WHITE)
            self.hit_books[#self.hit_books + 1] = {x=bx, y=by, w=math.max(projected_w, outer_x - bx), h=h+6, book=book}
            cursor = cursor + projected_w + gap
            index = index + 1
        end
    end
    if (self.page_num or 1) > 1 then
        drawText(bb, string.format("第 %d / %d 页  ·  左右滑动翻页", self.page or 1, self.page_num),
            x + width - 220, y + height - 18, 10, false, 205, BB.COLOR_GRAY_8)
    end
    local perf_elapsed = os.clock() - perf_started
    if perf_elapsed >= 0.2 then
        logger.info("simplebookshelf: paintShowcase elapsed", string.format("%.3fs", perf_elapsed), "books", tostring(#visible_books))
    end
end

-- Paint the shelf-owned wallpaper. No SimpleUI wallpaper API is involved.
function Shelf:paintWallpaper(bb, x, y)
    local showcase = self.tab == "showcase"
    local path = showcase and (showcaseWallpaperEnabled() and showcaseWallpaperPath() or nil)
        or (wallpaperEnabled() and wallpaperPath() or nil)
    local width = self.canvas and self.canvas.width or Screen:getWidth()
    local height = self.canvas and self.canvas.height or Screen:getHeight()
    local fit = showcase and showcaseWallpaperFitMode() or wallpaperFitMode()
    if not path then
        self:clearWallpaperCache()
        return false
    end

    if self._wallpaper_widget and self._wallpaper_path == path
            and self._wallpaper_fit == fit then
        local ok = pcall(self._wallpaper_widget.paintTo, self._wallpaper_widget, bb, x or 0, y or 0)
        return ok
    end

    self:clearWallpaperCache()
    self._wallpaper_path = path
    self._wallpaper_fit = fit
    local ok, widget = pcall(buildWallpaperWidget, path, width, height, fit)
    if ok and widget then
        self._wallpaper_widget = widget
        local painted = pcall(widget.paintTo, widget, bb, x or 0, y or 0)
        if painted then return true end
    end
    self._wallpaper_path = nil
    self._wallpaper_fit = nil
    return false
end

function Shelf:clearWallpaperCache()
    if self._wallpaper_widget and self._wallpaper_widget.free then
        pcall(self._wallpaper_widget.free, self._wallpaper_widget)
    end
    self._wallpaper_widget = nil
    self._wallpaper_path = nil
    self._wallpaper_fit = nil
end

function Shelf:refreshBooks(force)
    if self._scan_running then return end
    local now = os.time()
    if not force and self._last_scan_at and now - self._last_scan_at < 60 then return end
    self._scan_running = true
    local old_signature = booksSignature(self.books)
    local metadata_missing = false
    for _, book in ipairs(self.books or {}) do
        if book.metadata_text == nil or book.language == nil then
            metadata_missing = true
            break
        end
    end
    scanBooksAsync(self.scan_root, function(books)
        self._scan_running = false
        self._last_scan_at = os.time()
        if type(books) ~= "table" then return end
        scan_cache[self.scan_root] = books
        store:saveSetting("scan_cache", { root = self.scan_root, books = books, saved_at = self._last_scan_at })
        store:flush()
        if force or metadata_missing or booksSignature(books) ~= old_signature then
            self.books = books
            sortBooks(self.books)
            self.home_current_cache = nil
            self.home_statistics_cache = nil
            self.home_notes_cache = nil
            self:invalidateHomeRenderCache()
            if self.tab == "showcase" then self:buildShowcasePages() else self:buildPages() end
            UIManager:setDirty(self, "ui")
        end
    end)
end

function Shelf:setLibraryRoot(path)
    if path and path ~= "" then
        path = path == "/" and "/" or path:gsub("/+$", "")
        store:saveSetting("library_root", path)
    else
        store:delSetting("library_root")
        path = G_reader_settings:readSetting("home_dir") or "/mnt/us/documents"
    end
    store:delSetting("scan_cache")
    store:flush()
    scan_cache = {}
    self.scan_root = path
    self.books = {}
    self.home_current_cache = nil
    self.home_statistics_cache = nil
    self.home_notes_cache = nil
    self:invalidateHomeRenderCache()
    self.page = 1
    self:buildPages()
    UIManager:setDirty(self, "ui")
    self._last_scan_at = nil
    self:refreshBooks(true)
end

function Shelf:bookAt(position)
    for _, hit in ipairs(self.hit_books or {}) do
        if position.x >= hit.x and position.x <= hit.x + hit.w and position.y >= hit.y and position.y <= hit.y + hit.h then
            return hit.book
        end
    end
end

function Shelf:onTapBook(_, gesture)
    if self.tab == "stats" then
        if gesture.pos.y > 52 then
            local nav = self.stats_nav_hit or {}
            local function inside(hit)
                return hit and gesture.pos.x >= hit.x and gesture.pos.x <= hit.x + hit.w
                    and gesture.pos.y >= hit.y and gesture.pos.y <= hit.y + hit.h
            end
            if inside(self.stats_duration_hit) then
                self:showReadingDurationBreakdown(self.stats_duration_hit)
                return true
            elseif inside(nav.prev) then
                self:shiftStatsPeriod(-1)
                return true
            elseif inside(nav.next) then
                self:shiftStatsPeriod(1)
                return true
            end
            for _, hit in ipairs(nav.dots or {}) do
                if inside(hit) then self:setStatsView(hit.view); return true end
            end
            for _, hit in ipairs(self.stats_hit_books or {}) do
                if gesture.pos.x >= hit.x and gesture.pos.x <= hit.x + hit.w
                        and gesture.pos.y >= hit.y and gesture.pos.y <= hit.y + hit.h then
                    self.stats_selected_book = hit.title
                    self.stats_view = "book"
                    UIManager:setDirty(self, "ui")
                    break
                end
            end
        end
        return true
    end
    if self.tab == "home" then
        for _, hit in ipairs(self.home_action_hits or {}) do
            if gesture.pos.x >= hit.x and gesture.pos.x <= hit.x + hit.w
                    and gesture.pos.y >= hit.y and gesture.pos.y <= hit.y + hit.h then
                hit.callback()
                return true
            end
        end
    end
    if globalSetting("book_open_mode") == "double" then
        -- Consume a lone tap so it cannot fall through to another page or
        -- accidentally open a book. Long-press editing remains independent.
        return true
    end
    local book = self:bookAt(gesture.pos)
    if not book then return false end
    return openBookThroughFileManager(self, book.path)
end

function Shelf:onDoubleTapBook(_, gesture)
    if self.tab == "stats" then return true end
    if globalSetting("book_open_mode") ~= "double" then return false end
    local book = self:bookAt(gesture.pos)
    if not book then return false end
    return openBookThroughFileManager(self, book.path)
end

function Shelf:onHoldBook(_, gesture)
    if self.tab == "home" then
        for _, action in ipairs(self.home_hold_action_hits or {}) do
            if gesture.pos.x >= action.x and gesture.pos.x <= action.x + action.w
                    and gesture.pos.y >= action.y and gesture.pos.y <= action.y + action.h then
                action.callback()
                return true
            end
        end
        local hit = self.home_title_hit
        if hit and gesture.pos.x >= hit.x and gesture.pos.x <= hit.x + hit.w
                and gesture.pos.y >= hit.y and gesture.pos.y <= hit.y + hit.h then
            self:showHomeSettings()
        end
        return true
    end
    if self.tab == "stats" then
        local hit = self.stats_barcode_hit
        if hit and gesture.pos.x >= hit.x and gesture.pos.x <= hit.x + hit.w
                and gesture.pos.y >= hit.y and gesture.pos.y <= hit.y + hit.h then
            self:showReadingLineDateJump()
            return true
        end
        for _, record_hit in ipairs(self.stats_hit_records or {}) do
            if gesture.pos.x >= record_hit.x and gesture.pos.x <= record_hit.x + record_hit.w
                    and gesture.pos.y >= record_hit.y and gesture.pos.y <= record_hit.y + record_hit.h then
                self:showReadingRecordMenu(record_hit.boarding)
                return true
            end
        end
        return true
    end
    local book = self:bookAt(gesture.pos)
    if not book then
        -- Configuration is intentionally available only from the matching
        -- navbar item's long-press gesture.
        return true
    end
    if self.tab == "showcase" then
        self:showShowcaseBookEditor(book)
        return true
    end
    self:showBookEditor(book)
    return true
end

function Shelf:updateReadingRecord(record, field, value)
    local source = record and record.source_rows and record.source_rows[1]
    if not source or not source.rowid then return end
    if field == "page" then
        local source_total = tonumber(source.source_pages) or 0
        local local_total = tonumber(source.local_pages) or tonumber(source.pages) or 0
        if source_total > 0 and local_total > 0 then
            value = math.floor((tonumber(value) or 0) * source_total / local_total + .5)
        end
    end
    local ok, err = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
        local stmt = conn:prepare("UPDATE page_stat_data SET " .. field .. " = ? WHERE rowid = ?")
        stmt:bind(tonumber(value) or 0, source.rowid):step()
        stmt:close(); conn:close()
    end)
    if not ok then logger.warn("simplebookshelf: reading record update failed", err) end
    self._reading_rows_cache = nil
    self.home_statistics_cache = nil
    self:invalidateHomeRenderCache()
    UIManager:setDirty(self, "full")
end

function Shelf:deleteReadingRecord(record)
    local ok, err = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
        for _, source in ipairs(record and record.source_rows or {}) do
            if source.rowid then
                local stmt = conn:prepare("DELETE FROM page_stat_data WHERE rowid = ?")
                stmt:bind(source.rowid):step(); stmt:close()
            end
        end
        conn:close()
    end)
    if not ok then logger.warn("simplebookshelf: reading record delete failed", err) end
    self._reading_rows_cache = nil
    self.home_statistics_cache = nil
    self:invalidateHomeRenderCache()
    UIManager:setDirty(self, "full")
end

function Shelf:deleteReadingRows(rows)
    local ok, err = pcall(function()
        local SQ3 = require("lua-ljsqlite3/init")
        local conn = SQ3.open(DataStorage:getSettingsDir() .. "/statistics.sqlite3")
        for _, row in ipairs(rows or {}) do
            if row.rowid then
                local stmt = conn:prepare("DELETE FROM page_stat_data WHERE rowid = ?")
                stmt:bind(row.rowid):step(); stmt:close()
            end
        end
        conn:close()
    end)
    if not ok then logger.warn("simplebookshelf: ranked reading delete failed", err) end
    self._reading_rows_cache = nil
    self.home_statistics_cache = nil
    self:invalidateHomeRenderCache()
    UIManager:setDirty(self, "full")
end

function Shelf:deleteFinishedSnapshot(title)
    local snapshots = store:readSetting("reading_line_finished_snapshots") or {}
    local changed = false
    for key, snapshot in pairs(snapshots) do
        if snapshot.title == title then snapshots[key] = nil; changed = true end
    end
    if changed then
        store:saveSetting("reading_line_finished_snapshots", snapshots)
        store:flush()
    end
    UIManager:setDirty(self, "full")
end

function Shelf:showReadingBookDurationRecords(title, rows)
    local Menu = require("ui/widget/menu")
    local boardings = rlBoardings(rows or {})
    table.sort(boardings, function(a, b)
        if (a.duration or 0) == (b.duration or 0) then return (a.time or 0) > (b.time or 0) end
        return (a.duration or 0) > (b.duration or 0)
    end)
    local menu, items = nil, {}
    for i, boarding in ipairs(boardings) do
        local saved = boarding
        items[#items + 1] = {
            text=string.format("%02d  %s %s  ·  %s  ·  第 %d 页", i, os.date("%m.%d", saved.time), os.date("%H:%M", saved.time), rlTime(saved.duration), tonumber(saved.last_page or saved.first_page) or 0),
            callback=function()
                UIManager:close(menu)
                self:showReadingRecordMenu(saved)
            end,
        }
    end
    if #items == 0 then items[1] = {text="没有可显示的阅读记录"} end
    menu = Menu:new{
        items_font_size=PLUGIN_MENU_FONT_SIZE,
        items_mandatory_font_size=PLUGIN_MENU_FONT_SIZE,
        items_per_page=8,
        title="阅读记录：《" .. tostring(title or "") .. "》",
        item_table=items,
        width=math.floor(Screen:getWidth()*.84),
        height=math.floor(Screen:getHeight()*.68),
    }
    standardizePluginMenu(menu); UIManager:show(menu)
end

function Shelf:showReadingDurationBreakdown(hit)
    local Menu = require("ui/widget/menu")
    local owner = self
    local rows = self:readingRows(hit.from_ts or 0, hit.to_ts or (os.time()+1))
    if hit.book_title then
        local filtered = {}
        for _, row in ipairs(rows) do if row.title == hit.book_title then filtered[#filtered+1] = row end end
        rows = filtered
    end
    local aggregate = rlAggregate(rows)
    local ranked = {}
    for _, book in pairs(aggregate.books or {}) do ranked[#ranked+1] = book end
    local ranked_titles = {}
    for _, book in ipairs(ranked) do ranked_titles[book.title] = true end
    for _, snapshot in pairs(store:readSetting("reading_line_finished_snapshots") or {}) do
        if not ranked_titles[snapshot.title] and (not hit.from_ts or (snapshot.finished_at or 0) >= hit.from_ts) and (not hit.to_ts or (snapshot.finished_at or 0) < hit.to_ts) then
            ranked[#ranked + 1] = {title=snapshot.title, seconds=snapshot.seconds or 0, frozen=true}
        end
    end
    table.sort(ranked, function(a, b)
        if (a.seconds or 0) == (b.seconds or 0) then return tostring(a.title) < tostring(b.title) end
        return (a.seconds or 0) > (b.seconds or 0)
    end)
    local menu, items = nil, {}
    for i, book in ipairs(ranked) do
        local saved = book
        items[#items + 1] = {
            text=string.format("%02d  《%s》  ·  %s", i, rlEllipsize(saved.title, 22), rlTime(saved.seconds)),
            _rank_title=saved.title,
            callback=function()
                if saved.frozen then return end
                local selected = {}
                for _, row in ipairs(rows) do if row.title == saved.title then selected[#selected+1] = row end end
                UIManager:close(menu)
                self:showReadingBookDurationRecords(saved.title, selected)
            end,
        }
    end
    if #items == 0 then items[1] = {text="该时段没有阅读记录"} end
    menu = Menu:new{
        items_font_size=PLUGIN_MENU_FONT_SIZE,
        items_mandatory_font_size=PLUGIN_MENU_FONT_SIZE,
        items_per_page=8,
        title=(hit.label or "阅读时长") .. " · 书籍排行",
        item_table=items,
        width=math.floor(Screen:getWidth()*.84),
        height=math.floor(Screen:getHeight()*.68),
    }
    function menu:onMenuHold(item)
        if not item or not item._rank_title then return true end
        local title = item._rank_title
        local ConfirmBox = require("ui/widget/confirmbox")
        local rows_to_delete = {}
        for _, row in ipairs(rows) do if row.title == title then rows_to_delete[#rows_to_delete + 1] = row end end
        UIManager:show(ConfirmBox:new{
            text= #rows_to_delete > 0 and ("删除《" .. tostring(title) .. "》在此时间范围内的全部阅读记录？") or ("删除《" .. tostring(title) .. "》的保留阅读统计？"),
            ok_text="删除记录",
            ok_callback=function()
                if #rows_to_delete > 0 then owner:deleteReadingRows(rows_to_delete) else owner:deleteFinishedSnapshot(title) end
                UIManager:close(menu)
            end,
        })
        return true
    end
    standardizePluginMenu(menu); UIManager:show(menu)
end

function Shelf:showReadingRecordMenu(record)
    local Menu = require("ui/widget/menu")
    local InputDialog = require("ui/widget/inputdialog")
    local menu
    local first = record and record.source_rows and record.source_rows[1] or {}
    local minutes = math.max(0, math.floor((record and record.duration or 0) / 60))
    menu = Menu:new{items_font_size=PLUGIN_MENU_FONT_SIZE, items_mandatory_font_size=PLUGIN_MENU_FONT_SIZE, items_per_page=8, title="阅读记录：《" .. tostring(record and record.title or "") .. "》", item_table={
        {text="修改阅读时长（分钟）", callback=function()
            local dialog
            dialog = InputDialog:new{title="修改阅读时长", input=tostring(minutes), input_hint="分钟", buttons={{
                {text="取消", callback=function() UIManager:close(dialog) end},
                {text="保存", callback=function()
                    local value = tonumber(dialog:getInputText() or "")
                    if value and value >= 0 then self:updateReadingRecord(record, "duration", math.floor(value * 60)) end
                    UIManager:close(dialog); UIManager:close(menu)
                end},
            }}}
            UIManager:show(dialog)
        end},
        {text="修改页码", callback=function()
            local dialog
            dialog = InputDialog:new{title="修改页码", input=tostring(first.display_page or first.page or 0), input_hint="页码", buttons={{
                {text="取消", callback=function() UIManager:close(dialog) end},
                {text="保存", callback=function()
                    local value = tonumber(dialog:getInputText() or "")
                    if value and value >= 0 then self:updateReadingRecord(record, "page", math.floor(value)) end
                    UIManager:close(dialog); UIManager:close(menu)
                end},
            }}}
            UIManager:show(dialog)
        end},
        {text="删除这次阅读记录", callback=function()
            self:deleteReadingRecord(record); UIManager:close(menu)
        end},
    }, width=math.floor(Screen:getWidth()*.72), height=math.floor(Screen:getHeight()*.38)}
    menu.items_per_page = 3
    standardizePluginMenu(menu); UIManager:show(menu)
end

function Shelf:showReadingLineDateJump()
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{title="跳转阅读日期", input_hint="YYYY.MM.DD",
        input=os.date("%Y.%m.%d", self.stats_date or os.time()), buttons={{
        {text="取消", callback=function() UIManager:close(dialog) end},
        {text="跳转", callback=function()
            local value = dialog:getInputText() or ""
            local yy, mm, dd = value:match("^(%d%d%d%d)%.(%d%d?)%.(%d%d?)$")
            if yy and mm and dd then
                self.stats_date = os.time{year=tonumber(yy), month=tonumber(mm), day=tonumber(dd), hour=12, min=0, sec=0}
                UIManager:close(dialog); UIManager:setDirty(self, "full")
            end
        end},
    }}}
    UIManager:show(dialog)
end

function Shelf:showReadingLineMenu()
    local Menu = require("ui/widget/menu")
    local menu
    local views = {
        {"日票 · DAY TICKET", "day"}, {"周票 · WEEK TICKET", "week"},
        {"月票 · MONTH PASS", "month"}, {"年票 · YEAR PASS", "year"},
        {"单书行程票 · BOOK JOURNEY", "book"}, {"阅读屏保 · READING SCREEN", "screen"},
    }
    local items = {
        {text="上一张票", callback=function() self:shiftStatsPeriod(-1); UIManager:close(menu) end},
        {text="下一张票", callback=function() self:shiftStatsPeriod(1); UIManager:close(menu) end},
        {text="当前日期：" .. os.date("%Y.%m.%d", self.stats_date or os.time()), enabled_func=function() return false end},
    }
    for _, item in ipairs(views) do
        local label, view = item[1], item[2]
        items[#items + 1] = {text=label, checked_func=function() return self.stats_view == view end,
            callback=function() self:setStatsView(view); UIManager:close(menu) end}
    end
    items[#items + 1] = {text="统计页面设置", callback=function() UIManager:close(menu); self:showStatsSettings() end}
    menu = Menu:new{items_font_size=PLUGIN_MENU_FONT_SIZE, items_mandatory_font_size=PLUGIN_MENU_FONT_SIZE, title="READING LINE", item_table=items,
        width=math.floor(Screen:getWidth()*.76), height=math.floor(Screen:getHeight()*.62)}
    standardizePluginMenu(menu); UIManager:show(menu)
end

function Shelf:showShowcaseBookEditor(book)
    local Menu = require("ui/widget/menu")
    local style = showcaseBookStyle(book.path)
    local menu
    local function set(key, value)
        updateShowcaseBookStyle(book.path, key, value)
        self:refreshLayout()
        UIManager:setDirty(self, "ui")
    end
    local function levels(key, values, labels)
        local items = {}
        for i, value in ipairs(values) do
            local saved = value
            items[#items + 1] = {text=labels[i], checked_func=function() return style[key] == saved end,
                callback=function() style[key]=saved; set(key, saved); UIManager:close(menu) end}
        end
        return items
    end
    menu = Menu:new{items_font_size=PLUGIN_MENU_FONT_SIZE, items_mandatory_font_size=PLUGIN_MENU_FONT_SIZE,
        title="单本大小：《" .. tostring(book.title or "") .. "》",
        item_table=levels("width", {48, 65, 85, 105, 125}, {"一档 · 较小", "二档 · 标准", "三档 · 较大", "四档 · 很大", "五档 · 最大"}),
        width=math.floor(Screen:getWidth()*.62), height=math.floor(Screen:getHeight()*.36)}
    standardizePluginMenu(menu); UIManager:show(menu)
end

function Shelf:onSwipePage(_, gesture)
    if self.tab == "stats" then
        if self.stats_view == "day" and (gesture.direction == "north" or gesture.direction == "south") then
            local rows = self:readingRows(rlDayStart(self.stats_date), rlDayStart(self.stats_date) + 86400)
            local pages = math.max(1, math.ceil(#rlBoardings(rows) / 7))
            local page = tonumber(self.stats_boarding_page) or 1
            if gesture.direction == "north" then page = math.min(pages, page + 1)
            else page = math.max(1, page - 1) end
            if page ~= self.stats_boarding_page then
                self.stats_boarding_page = page
                UIManager:setDirty(self, "full")
            end
            return true
        end
        local views = enabledStatsViews()
        local current = 1
        for i, view in ipairs(views) do if view == self.stats_view then current = i; break end end
        if gesture.direction == "west" then current = (current % #views) + 1
        elseif gesture.direction == "east" then current = ((current - 2) % #views) + 1
        else return false end
        self:setStatsView(views[current])
        return true
    end
    if gesture.direction == "west" and self.page < self.page_num then self.page = self.page + 1
    elseif gesture.direction == "east" and self.page > 1 then self.page = self.page - 1
    else return false end
    UIManager:setDirty(self, "ui")
    return true
end

function Shelf:onNextPage() if self.page < self.page_num then self.page=self.page+1;UIManager:setDirty(self,"ui") end return true end
function Shelf:onPrevPage() if self.page > 1 then self.page=self.page-1;UIManager:setDirty(self,"ui") end return true end
function Shelf:onGotoPage(page) self.page=math.max(1,math.min(page,self.page_num));UIManager:setDirty(self,"ui");return true end

function Shelf:refreshLayout()
    if self.tab == "showcase" then self:buildShowcasePages() else self:buildPages() end
    UIManager:setDirty(self, "ui")
end

-- A spine image changes only one placement. Rebuilding every page here is
-- needlessly expensive on Scribe and can decode all custom images again.
function Shelf:updateBookSpine(book_path, image_path)
    for _, page in ipairs(self.pages or {}) do
        for _, placement in ipairs(page) do
            if placement.book and placement.book.path == book_path and placement.style then
                placement.style.custom_spine = image_path
            end
        end
    end
    UIManager:setDirty(self, "ui")
end

function Shelf:showBookEditor(book)
    local Menu = require("ui/widget/menu")
    local style = bookStyle(book.path, self.standalone)
    local editor_menu
    local function set(key, value)
        updateBookStyle(book.path, key, value)
        self:refreshLayout()
        refreshTopMenu()
    end
    local items = {
        { text="外观", sub_item_table={
            { text="宽度", sub_item_table={
                {text="自动 · 按页数",checked_func=function()local ov=book_overrides[book.path];return type(ov)~="table" or ov.width==nil end,callback=function()style.width=defaultSpineWidthForPages(book.pages);set("width",nil)end},
                {text="一档 · 最窄",checked_func=function()local ov=book_overrides[book.path];return type(ov)=="table" and ov.width==38 end,callback=function()style.width=38;set("width",38)end},
                {text="二档 · 较窄",checked_func=function()local ov=book_overrides[book.path];return type(ov)=="table" and ov.width==50 end,callback=function()style.width=50;set("width",50)end},
                {text="三档 · 适中",checked_func=function()local ov=book_overrides[book.path];return type(ov)=="table" and ov.width==65 end,callback=function()style.width=65;set("width",65)end},
                {text="四档 · 较宽",checked_func=function()local ov=book_overrides[book.path];return type(ov)=="table" and ov.width==85 end,callback=function()style.width=85;set("width",85)end},
                {text="五档 · 最宽",checked_func=function()local ov=book_overrides[book.path];return type(ov)=="table" and ov.width==110 end,callback=function()style.width=110;set("width",110)end},
            }},
            { text="高度", sub_item_table={
                {text="一档 · 最矮",checked_func=function()return style.height_pct==60 end,callback=function()style.height_pct=60;set("height_pct",60)end},
                {text="二档 · 较矮",checked_func=function()return style.height_pct==70 end,callback=function()style.height_pct=70;set("height_pct",70)end},
                {text="三档 · 适中",checked_func=function()return style.height_pct==80 end,callback=function()style.height_pct=80;set("height_pct",80)end},
                {text="四档 · 较高",checked_func=function()return style.height_pct==90 end,callback=function()style.height_pct=90;set("height_pct",90)end},
                {text="五档 · 最高",checked_func=function()return style.height_pct==100 end,callback=function()style.height_pct=100;set("height_pct",100)end},
            }},
            { text="圆角", sub_item_table={
                {text="一档 · 直角",checked_func=function()return style.corner==0 end,callback=function()style.corner=0;set("corner",0)end},
                {text="二档 · 轻微",checked_func=function()return style.corner==3 end,callback=function()style.corner=3;set("corner",3)end},
                {text="三档 · 自然",checked_func=function()return style.corner==6 end,callback=function()style.corner=6;set("corner",6)end},
                {text="四档 · 明显",checked_func=function()return style.corner==10 end,callback=function()style.corner=10;set("corner",10)end},
                {text="五档 · 很圆",checked_func=function()return style.corner==16 end,callback=function()style.corner=16;set("corner",16)end},
            }},
        }},
        { text="书名", sub_item_table={
            { text_func=function() return "显示书名："..(style.show_title == false and "关" or "开") end,
              callback=function()
                  style.show_title = style.show_title == false
                  set("show_title", style.show_title)
              end },
            { text_func=function() return "字号："..style.font_size end, callback=function()spinner("书名字号",style.font_size,3,48,1,function(v)style.font_size=v;set("font_size",v)end)end },
            { text_func=function() return "字距："..(style.line_spacing or 20) end, callback=function()spinner("书名纵向字距",style.line_spacing or 20,3,80,1,function(v)style.line_spacing=v;set("line_spacing",v)end)end },
            { text="位置", sub_item_table={
                {text="顶部",checked_func=function()return style.title_vpos=="top"end,callback=function()style.title_vpos="top";set("title_vpos","top")end},
                {text="偏上",checked_func=function()return style.title_vpos=="upper"end,callback=function()style.title_vpos="upper";set("title_vpos","upper")end},
                {text="居中",checked_func=function()return style.title_vpos=="center"end,callback=function()style.title_vpos="center";set("title_vpos","center")end},
                {text="偏下",checked_func=function()return style.title_vpos=="lower"end,callback=function()style.title_vpos="lower";set("title_vpos","lower")end},
                {text="底部",checked_func=function()return style.title_vpos=="bottom"end,callback=function()style.title_vpos="bottom";set("title_vpos","bottom")end},
            }},
            { text="颜色", sub_item_table={
                {text="白色",checked_func=function()return style.text_color=="white"end,callback=function()style.text_color="white";set("text_color","white")end},
                {text="近白",checked_func=function()return style.text_color=="pale"end,callback=function()style.text_color="pale";set("text_color","pale")end},
                {text="浅灰",checked_func=function()return style.text_color=="light"end,callback=function()style.text_color="light";set("text_color","light")end},
                {text="中灰",checked_func=function()return style.text_color=="medium"end,callback=function()style.text_color="medium";set("text_color","medium")end},
                {text="深灰",checked_func=function()return style.text_color=="dark"end,callback=function()style.text_color="dark";set("text_color","dark")end},
                {text="黑色",checked_func=function()return style.text_color=="black"end,callback=function()style.text_color="black";set("text_color","black")end},
            }},
        }},
        { text="书脊", sub_item_table={
            { text="图片", sub_item_table={
                { text_func=function() return "默认封面"..(style.custom_spine and "" or "  ✓") end,
                  callback=function()
                      style.custom_spine=nil
                      set("custom_spine",nil)
                  end },
                { text="手机上传", callback=function()
                    local InfoMessage=require("ui/widget/infomessage")
                    local ok_uploader,Uploader=pcall(function()
                        if not package.loaded.simplebookshelf_spine_upload then
                            package.loaded.simplebookshelf_spine_upload=dofile(PLUGIN_DIR.."/spine_upload.lua")
                        end
                        return package.loaded.simplebookshelf_spine_upload
                    end)
                    if not ok_uploader then UIManager:show(InfoMessage:new{text="上传组件无法加载",timeout=3});return end
                    local url,err=Uploader.start(book.path,function(path)
                        style.custom_spine=path
                        updateBookStyle(book.path,"custom_spine",path)
                        -- Let the upload dialog/server finish and repaint the
                        -- local shelf before doing any optional WebDAV work.
                        -- Calling both immediately used to make Scribe appear
                        -- frozen while the new image was decoded and the
                        -- network request was still running.
                        UIManager:scheduleIn(0.15, function()
                            if Shelf.instance == self then self:updateBookSpine(book.path,path) end
                        end)
                        local cloud_configured = false
                        pcall(function() cloud_configured = Cloud.isConfigured() end)
                        if cloud_configured then
                            UIManager:show(InfoMessage:new{
                                text = "书脊已上传，本地已保存；共享库稍后同步",
                                timeout = 3,
                            })
                            UIManager:scheduleIn(1.0, function()
                                local call_ok, synced, sync_err = pcall(Cloud.upload, book.path, path)
                                if not call_ok then synced, sync_err = false, tostring(synced) end
                                UIManager:show(InfoMessage:new{
                                    text = synced and "书脊已同步到共享库"
                                        or ("共享库同步失败：" .. tostring(sync_err or "未知错误")),
                                    timeout = 4,
                                })
                            end)
                        else
                            UIManager:show(InfoMessage:new{text="自定义书脊上传成功",timeout=3})
                        end
                    end)
                    if not url then UIManager:show(InfoMessage:new{text=err or "无法开始上传",timeout=3}) end
                end },
                { text="从共享库获取", enabled_func=function() return cloudConfigured() end,
                  callback=function()
                      local InfoMessage=require("ui/widget/infomessage")
                      local cache_dir=DataStorage:getSettingsDir().."/simplebookshelf_spines"
                      UIManager:show(InfoMessage:new{text="正在从共享库获取…",timeout=45})
                      local async_ok = pcall(function()
                          Cloud.downloadAsync(book.path, cache_dir, function(path, err)
                              if path then
                                  style.custom_spine=path
                                  updateBookStyle(book.path,"custom_spine",path)
                                  UIManager:scheduleIn(0.1, function()
                                      if Shelf.instance == self then self:updateBookSpine(book.path,path) end
                                  end)
                                  UIManager:show(InfoMessage:new{text="已从共享库获取书脊图片",timeout=3})
                              else
                                  UIManager:show(InfoMessage:new{text=err or "共享库中没有这本书",timeout=4})
                              end
                          end)
                      end)
                      if not async_ok then
                          UIManager:show(InfoMessage:new{text="共享库下载组件启动失败",timeout=4})
                      end
                  end },
                { text="上传当前图片到共享库",
                  enabled_func=function() return style.custom_spine ~= nil and cloudConfigured() end,
                  callback=function()
                      local InfoMessage=require("ui/widget/infomessage")
                      local call_ok,ok,err=pcall(Cloud.upload,book.path,style.custom_spine)
                      if not call_ok then ok,err=false,tostring(ok) end
                      UIManager:show(InfoMessage:new{
                          text=ok and "当前书脊图片已上传到共享库"
                              or (err or "上传共享书脊失败"), timeout=4,
                      })
                  end },
                { text="删除自定义图片", enabled_func=function()return style.custom_spine~=nil end,
                  callback=function()
                      if style.custom_spine then pcall(os.remove,style.custom_spine) end
                      style.custom_spine=nil
                      set("custom_spine",nil)
                  end },
            }},
            { text="适配方式", sub_item_table={
                {text="保持比例并裁切",checked_func=function()return style.spine_fit=="crop"end,callback=function()style.spine_fit="crop";set("spine_fit","crop")end},
                {text="拉伸填满",checked_func=function()return style.spine_fit=="stretch"end,callback=function()style.spine_fit="stretch";set("spine_fit","stretch")end},
            }},
            { text="取图", sub_item_table={
                {text="左侧",checked_func=function()return style.crop_align=="left"end,callback=function()style.crop_align="left";set("crop_align","left")end},
                {text="中间",checked_func=function()return style.crop_align=="center"end,callback=function()style.crop_align="center";set("crop_align","center")end},
                {text="右侧",checked_func=function()return style.crop_align=="right"end,callback=function()style.crop_align="right";set("crop_align","right")end},
            }},
            { text_func=function() return "宽度："..style.crop_pct.."%" end, callback=function()spinner("封面截取宽度",style.crop_pct,8,60,1,function(v)style.crop_pct=v;set("crop_pct",v)end)end },
        }},
        { text="恢复默认",callback=function()book_overrides[book.path]=nil;saveOverrides();self:refreshLayout()end },
    }
    editor_menu = Menu:new{items_font_size=PLUGIN_MENU_FONT_SIZE, items_mandatory_font_size=PLUGIN_MENU_FONT_SIZE, items_per_page=8, title="编辑：《"..book.title.."》", item_table=items,
        width=math.floor(Screen:getWidth()*.72),height=math.floor(Screen:getHeight()*.82) }
    -- Menu recalculation may replace items_font_size with a smaller derived
    -- value.  Lock the final faces as well, matching the global settings menu.
    standardizePluginMenu(editor_menu); UIManager:show(editor_menu)
end

function Shelf:showGlobalSettings()
    local Menu = require("ui/widget/menu")
    local settings_menu
    local function setGlobalAndPaint(key, value)
        saveGlobal(key, value)
        if key == "shelf_rows" or key == "book_left_margin_level" or key == "book_right_margin_level"
                or key == "book_top_margin_level" or key == "book_scale" then
            self:buildPages()
        end
        UIManager:setDirty(self,"ui")
        refreshTopMenu()
    end
    local function fiveLevels(key, values, labels)
        local result = {}
        for i, value in ipairs(values) do
            local saved_value, label = value, labels[i]
            result[#result + 1] = {
                text = label,
                checked_func = function() return globalSetting(key) == saved_value end,
                callback = function() setGlobalAndPaint(key, saved_value) end,
            }
        end
        return result
    end
    local function setUnifiedTypography(embedded_key, standalone_key, title, current, min_value, max_value)
        spinner(title, current, min_value, max_value, 1, function(v)
            saveGlobal(embedded_key, v)
            saveGlobal(standalone_key, v)
            self:buildPages()
            UIManager:setDirty(self, "ui")
            refreshTopMenu()
        end)
    end
    local wallpaper_items = {
        { text="不使用壁纸", callback=function()
            setWallpaperPath(nil)
            setWallpaperEnabled(false)
            self:clearWallpaperCache()
            UIManager:setDirty(self,"ui")
        end },
    }
    for _, wallpaper in ipairs(scanWallpapers()) do
        local item = wallpaper
        wallpaper_items[#wallpaper_items+1] = {
            text=item.label,
            checked_func=function() return wallpaperEnabled() and wallpaperPath() == item.path end,
            callback=function()
                setWallpaperPath(item.path)
                setWallpaperEnabled(true)
                self:clearWallpaperCache()
                UIManager:setDirty(self,"ui")
            end,
        }
    end
    local wallpaper_folder_items = {
        {text_func=function() return "当前：" .. wallpaperDir() end, enabled_func=function() return false end},
        {text="使用书柜默认文件夹", callback=function()
            if settings_menu then UIManager:close(settings_menu) end
            setWallpaperDir(nil)
            UIManager:setDirty(self, "ui")
            refreshTopMenu()
        end},
        {text="选择其他文件夹…", callback=function()
            if settings_menu then UIManager:close(settings_menu) end
            local PathChooser = require("ui/widget/pathchooser")
            UIManager:show(PathChooser:new{
                path=wallpaperDir(), select_directory=true, select_file=false, show_files=false,
                onConfirm=function(folder)
                    setWallpaperDir(folder)
                    UIManager:setDirty(self, "ui")
                    refreshTopMenu()
                end,
            })
        end},
    }
    local sort_items = {
            {text="正在读 → 待读 → 已读完",checked_func=function()return globalSetting("sort_mode")=="status"end,callback=function()saveGlobal("sort_mode","status");sortBooks(self.books);self:buildPages();UIManager:setDirty(self,"ui")end},
            {text="书名",checked_func=function()return globalSetting("sort_mode")=="title"end,callback=function()saveGlobal("sort_mode","title");sortBooks(self.books);self:buildPages();UIManager:setDirty(self,"ui")end},
            {text="添加日期",checked_func=function()return globalSetting("sort_mode")=="added"end,callback=function()saveGlobal("sort_mode","added");sortBooks(self.books);self:buildPages();UIManager:setDirty(self,"ui")end},
            {text="阅读日期",checked_func=function()return globalSetting("sort_mode")=="read"end,callback=function()saveGlobal("sort_mode","read");sortBooks(self.books);self:buildPages();UIManager:setDirty(self,"ui")end},
    }
    local folder_items = {
        {text_func=function()return "当前："..libraryRoot()end,enabled_func=function()return false end},
        {text="使用当前 Kindle 书库",callback=function()
            if settings_menu then UIManager:close(settings_menu) end
            self:setLibraryRoot(nil)
        end},
        {text="选择其他文件夹…",callback=function()
            if settings_menu then UIManager:close(settings_menu) end
            local PathChooser = require("ui/widget/pathchooser")
            UIManager:show(PathChooser:new{
                path=libraryRoot(),select_directory=true,select_file=false,show_files=false,
                onConfirm=function(folder) self:setLibraryRoot(folder) end,
            })
        end},
    }
    local items = {
        {text="立体度",sub_item_table={
            {text="书本",sub_item_table=fiveLevels("book_3d_level",{1,2,3,4},{"一档 · 最弱 · 浅灰","二档 · 较弱 · 中灰","三档 · 较强 · 深灰","四档 · 最强 · 近黑"})},
            {text="书架",sub_item_table=fiveLevels("shelf_3d_level",{1,2,3,4},{"一档 · 最弱 · 浅灰","二档 · 较弱 · 中灰","三档 · 较强 · 深灰","四档 · 最强 · 近黑"})},
        }},
        {text="隔板",sub_item_table={
            {text="行数",sub_item_table=fiveLevels("shelf_rows",{1,2,3,4,5},{"一行","二行","三行 · 默认","四行","五行"})},
            {text="厚度",sub_item_table=fiveLevels("shelf_thickness",{16,20,24,30,36},{"一档 · 最窄","二档 · 较窄","三档 · 适中","四档 · 较宽","五档 · 最宽"})},
        }},
        {text="全局默认",sub_item_table={
            {text="边距",sub_item_table={
                {text="左边距",sub_item_table=fiveLevels("book_left_margin_level",{1,2,3,4,5},{"一档 · 最窄","二档 · 默认","三档 · 适中","四档 · 较宽","五档 · 最宽"})},
                {text="右边距",sub_item_table=fiveLevels("book_right_margin_level",{1,2,3,4,5},{"一档 · 最窄","二档 · 默认","三档 · 适中","四档 · 较宽","五档 · 最宽"})},
                {text="上边留白",sub_item_table=fiveLevels("book_top_margin_level",{1,2,3,4,5},{"一档 · 最少","二档 · 较少","三档 · 默认","四档 · 较多","五档 · 最多"})},
            }},
            {text_func=function() return "字号：" .. tostring(globalSetting("embedded_font_size")) end,
             callback=function() setUnifiedTypography("embedded_font_size", "standalone_font_size", "字号", globalSetting("embedded_font_size"), 3, 48) end},
            {text_func=function() return "字距：" .. tostring(globalSetting("embedded_line_spacing")) end,
             callback=function() setUnifiedTypography("embedded_line_spacing", "standalone_line_spacing", "字距", globalSetting("embedded_line_spacing"), 3, 80) end},
            {text="排序方式",sub_item_table=sort_items},
            {text="书籍文件夹",sub_item_table=folder_items},
            {text="书本大小比例",sub_item_table={
                {text_func=function() return "当前："..(globalSetting("book_scale") or 100).."%" end,
                 callback=function() spinner("书本大小比例(%)", globalSetting("book_scale") or 100, 50, 150, 5, function(v) setGlobalAndPaint("book_scale", v) end) end},
            }},
        }},
    }
    items[#items + 1] = {text="壁纸",sub_item_table={
        {text="壁纸文件夹",sub_item_table=wallpaper_folder_items},
        {text="选择壁纸",sub_item_table=wallpaper_items},
        {text="填充方式",sub_item_table={
            {text="原尺寸",checked_func=function() return wallpaperFitMode() == "original" end,
             callback=function() setWallpaperFitMode("original"); self:clearWallpaperCache(); UIManager:setDirty(self,"ui") end},
            {text="拉伸",checked_func=function() return wallpaperFitMode() == "stretch" end,
             callback=function() setWallpaperFitMode("stretch"); self:clearWallpaperCache(); UIManager:setDirty(self,"ui") end},
            {text="铺满",checked_func=function() return wallpaperFitMode() == "fill" end,
             callback=function() setWallpaperFitMode("fill"); self:clearWallpaperCache(); UIManager:setDirty(self,"ui") end},
        }},
    }}
    local geometry = navColumnMenuGeometry(self.tab, .72)
    settings_menu = Menu:new{items_font_size=PLUGIN_MENU_FONT_SIZE, items_mandatory_font_size=PLUGIN_MENU_FONT_SIZE, item_table=items,x=geometry.x,y=geometry.y,width=geometry.width,height=geometry.height}
    standardizePluginMenu(settings_menu); UIManager:show(settings_menu, nil, nil, geometry.x, geometry.y)
end

function Shelf:onCloseAllMenus() UIManager:close(self); return true end
function Shelf:onClose() UIManager:close(self); return true end
function Shelf:onCloseWidget()
    self:clearWallpaperCache()
    self:invalidateHomeRenderCache()
    if Shelf.instance == self then Shelf.instance = nil end
end

local Plugin = WidgetContainer:extend{
    name = "simplebookshelf",
    is_doc_only = false,
}

function Plugin:showShelf(sui_plugin, standalone)
    -- This line is always a standalone page, regardless of who invokes it.
    standalone = true
    if Shelf.instance and Shelf.instance.standalone ~= standalone then
        local old = Shelf.instance
        Shelf.instance = nil
        if UIManager:isWidgetShown(old) then UIManager:close(old) end
    end
    if Shelf.instance and not UIManager:isWidgetShown(Shelf.instance) then
        Shelf.instance = nil
    end
    if Shelf.instance then
        -- The current page owns the live navbar. Never mutate UIManager's
        -- private window stack here; doing so bypasses close callbacks and was
        -- the other source of dead navigation after a reader session.
        Shelf.instance.sui_plugin = sui_plugin or Shelf.instance.sui_plugin
        UIManager:setDirty(Shelf.instance,"full")
        UIManager:scheduleIn(.1, function()
            if Shelf.instance then Shelf.instance:refreshBooks(false) end
        end)
        closeSwitchBlocker()
        return true
    end
    local return_tab = G_reader_settings:readSetting("simplebookshelf_return_tab")
    if return_tab ~= "home" and return_tab ~= "bookshelf" and return_tab ~= "showcase" and return_tab ~= "stats" then
        return_tab = nil
    end
    Shelf.instance = Shelf:new{ sui_plugin=sui_plugin or self.sui_plugin, owner_plugin=self, standalone=standalone, tab=return_tab }
    if return_tab then
        G_reader_settings:delSetting("simplebookshelf_return_tab")
        G_reader_settings:flush()
    end
    UIManager:show(Shelf.instance)
    Shelf.instance:startHomeClockRefresh()
    UIManager:nextTick(function()
        if Shelf.instance then UIManager:setDirty(Shelf.instance, "full") end
    end)
    closeSwitchBlocker()
    return true
end

-- Resolve a SimpleUI module by trying its 2.5.0 path first and falling back
-- to the legacy bare alias. SimpleUI 2.5.0 moved its modules under infra/ and
-- features/ and stopped registering bare require aliases (sui_config /
-- sui_quickactions), so the old require("sui_config") started failing and the
-- whole integration silently no-op'd.
function Plugin:_requireSui(mod_new, mod_old)
    local modules = SimpleUI.resolve()
    if not modules then return nil end
    local by_path = {
        ["infra/sui_core"] = modules.UI,
        ["sui_core"] = modules.UI,
        ["infra/sui_config"] = modules.Config,
        ["sui_config"] = modules.Config,
        ["infra/sui_store"] = modules.Store,
        ["sui_store"] = modules.Store,
        ["features/sui_quickactions"] = modules.Actions,
        ["sui_quickactions"] = modules.Actions,
        ["screens/sui_bottombar"] = modules.Bottombar,
        ["sui_bottombar"] = modules.Bottombar,
        ["features/sui_style"] = modules.Style,
        ["sui_style"] = modules.Style,
    }
    return by_path[mod_new] or by_path[mod_old]
end

-- Best-effort lookup of the live SimpleUI plugin instance (needed to rebuild
-- its navbar). Prefer the FileManager reference; fall back to the module cache.
function Plugin:_resolveSuiPlugin()
    local fm = self.ui
    if not (fm and fm._simpleui_plugin) then
        local FM = package.loaded["apps/filemanager/filemanager"]
        fm = FM and FM.instance
    end
    return (fm and fm._simpleui_plugin) or self.sui_plugin or nil
end

function Plugin:registerSimpleUI()
    if self._simpleui_registered then return true end
    local Config  = self:_requireSui("infra/sui_config", "sui_config")
    local Actions = self:_requireSui("features/sui_quickactions", "sui_quickactions")
    if not (Config and Actions) then
        -- SimpleUI not loaded yet (plugin load order differs). Caller retries.
        return false
    end
    local owner=self
    SimpleUI.registerAction{
        id="simplebookshelf",label="Reading Line",icon=PLUGIN_DIR.."/bookshelf.svg",
        -- This is a real navigable page, not a dialog/toggle. Marking it
        -- in-place prevents SimpleUI from closing the previous page and
        -- rebuilding its touch zones when switching from bookshelf-home.
        is_in_place=false,
        execute=function(context)
            local sui_plugin = (context and context.plugin)
                or owner:_resolveSuiPlugin()
                or owner.sui_plugin
            owner.sui_plugin = sui_plugin
            local old = Shelf.instance
            -- Navigation has already closed the previous auxiliary page.
            -- Resolve a deferred singleton immediately so we never stop on the
            -- native library while waiting for a timer callback.
            if old and not UIManager:isWidgetShown(old) and Shelf.instance == old then
                Shelf.instance = nil
            end
            owner:showShelf(sui_plugin)
        end,
    }
    self._simpleui_registered = true
    if Config.invalidateTabsCache then Config.invalidateTabsCache() end
    -- SimpleUI owns the saved tab list. Do not add, remove, or migrate tabs
    -- here: the current list is read dynamically whenever a page is wrapped.
    -- If SimpleUI is already on screen, rebuild it using that current list.
    self:_rebuildNavbar(Config)
    logger.info("simplebookshelf: integrated SimpleUI bookshelf registered")
    return true
end

function Plugin:_rebuildNavbar(Config)
    local Bottombar = self:_requireSui("screens/sui_bottombar", "sui_bottombar")
    if not (Bottombar and Bottombar.rebuildAllNavbars) then return end
    local sui_plugin = self:_resolveSuiPlugin()
    if sui_plugin then
        pcall(Bottombar.rebuildAllNavbars, sui_plugin)
    end
end

function Plugin:_stopReadingLineTextIndex()
    self._reading_line_text_index_token = (self._reading_line_text_index_token or 0) + 1
    self._reading_line_text_index_doc = nil
end

function Plugin:_startReadingLineTextIndex(config)
    self:_stopReadingLineTextIndex()
    local doc = self.ui and self.ui.document
    local path = doc and doc.file
    if not doc or not self.ui.rolling or not isReadingLineTextBook(path)
            or not doc.getPageXPointer or not doc.getTextFromXPointers then return end
    local md5 = config and config:readSetting("partial_md5_checksum") or ""
    local ok_pages, total_pages = pcall(doc.getPageCount, doc)
    total_pages = ok_pages and math.max(0, tonumber(total_pages) or 0) or 0
    local key = readingLineTextIndexKey(md5, total_pages)
    if not key then return end

    local indexes = store:readSetting("reading_line_text_indexes") or {}
    local index = indexes[key]
    if type(index) ~= "table" or tonumber(index.pages) ~= total_pages
            or type(index.cumulative) ~= "table" then
        index = {md5=md5, pages=total_pages, cumulative={0}, complete=false, last_used=os.time()}
        indexes[key] = index
    end
    if index.complete and #index.cumulative >= total_pages then return end

    index.last_used = os.time()
    local page = math.max(1, #index.cumulative)
    local token = self._reading_line_text_index_token
    self._reading_line_text_index_doc = doc

    local function saveIndex()
        index.last_used = os.time()
        local keys = {}
        for saved_key, saved in pairs(indexes) do
            keys[#keys + 1] = {key=saved_key, used=tonumber(saved.last_used) or 0}
        end
        table.sort(keys, function(a, b) return a.used > b.used end)
        for i = 13, #keys do indexes[keys[i].key] = nil end
        store:saveSetting("reading_line_text_indexes", indexes)
        store:flush()
    end

    local function buildNext()
        if token ~= self._reading_line_text_index_token
                or self._reading_line_text_index_doc ~= doc then return end
        local processed = 0
        while page < total_pages and processed < 2 do
            local ok0, xp0 = pcall(doc.getPageXPointer, doc, page)
            local ok1, xp1 = pcall(doc.getPageXPointer, doc, page + 1)
            if not ok0 or not ok1 or not xp0 or not xp1 then
                saveIndex()
                return
            end
            local ok_text, text = pcall(doc.getTextFromXPointers, doc, xp0, xp1)
            if not ok_text then
                saveIndex()
                return
            end
            index.cumulative[page + 1] = (tonumber(index.cumulative[page]) or 0)
                + readingLineCountTextChars(text)
            page = page + 1
            processed = processed + 1
            if page % 16 == 0 then saveIndex() end
        end
        if page >= total_pages then
            index.complete = true
            saveIndex()
            self._reading_line_text_index_doc = nil
            return
        end
        UIManager:scheduleIn(.03, buildNext)
    end
    UIManager:scheduleIn(.8, buildNext)
end

function Plugin:onReaderReady(config)
    self:_startReadingLineTextIndex(config)
end

function Plugin:init()
    Dispatcher:init()
    Dispatcher:registerAction("simplebookshelf_show",{category="none",event="ShowSimpleBookshelf",title="打开 Reading Line",general=true})
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end
    -- "Enabled" means this page is the home screen. Open it only when this
    -- exact plugin instance belongs to the live FileManager; ReaderUI loads the
    -- same non-doc plugin, so checking document alone is not sufficient.
    local host = self.ui
    if pluginEnabled() and host then
        local attempts = 0
        local function showOnFileManager()
            attempts = attempts + 1
            if self.ui ~= host or host.tearing_down then return end
            local ReaderUI = package.loaded["apps/reader/readerui"]
            if ReaderUI and ReaderUI.instance then return end
            local fm = liveFileManager()
            if fm == host then
                logger.info("simplebookshelf: enabled FileManager home takeover")
                self:showShelf(self:_resolveSuiPlugin(), true)
            elseif attempts < 6 then
                UIManager:scheduleIn(.2, showOnFileManager)
            end
        end
        UIManager:scheduleIn(.2, showOnFileManager)
    end
end
function Plugin:onShowSimpleBookshelf()
    if Shelf.instance and Shelf.instance.standalone and UIManager:isWidgetShown(Shelf.instance) then
        UIManager:close(Shelf.instance)
        return true
    end
    return self:showShelf(self.sui_plugin, true)
end
function Plugin:onCloseDocument()
    self:_stopReadingLineTextIndex()
    -- Preserve the origin for the complete synchronous CloseDocument
    -- dispatch. The other installed bookshelf plugin reads the same marker;
    -- deleting it here made that plugin see origin=nil and return to KOReader's
    -- native library. Clear it on the next UI turn after all listeners ran.
    local origin = UIManager._simpleui_book_origin
        or G_reader_settings:readSetting("simpleui_book_origin")
    logger.info("simplebookshelf: CloseDocument origin=", tostring(origin))
    if origin == "simplebookshelf" then
        UIManager:nextTick(function()
            if UIManager._simpleui_book_origin == "simplebookshelf" then
                UIManager._simpleui_book_origin = nil
            end
            if G_reader_settings:readSetting("simpleui_book_origin") == "simplebookshelf" then
                G_reader_settings:delSetting("simpleui_book_origin")
                G_reader_settings:flush()
            end
        end)
    end
    return false
end
function Plugin:toggleEnabled()
    local enabled = not pluginEnabled()
    setPluginEnabled(enabled)
    if enabled then
        self:showShelf(nil, true)
    else
        closeShelfInstance()
    end
    return true
end

function Plugin:showNavigationOrderDialog()
    local ButtonDialog = require("ui/widget/buttondialog")
    local dialog
    local order = navigationOrder()
    local buttons = {}
    local function move(tab, direction)
        local current = navigationOrder()
        local index
        for i, candidate in ipairs(current) do
            if candidate == tab then index = i; break end
        end
        local target = index and (index + direction) or nil
        if target and target >= 1 and target <= #current then
            current[index], current[target] = current[target], current[index]
            saveNavigationOrder(current)
            if Shelf.instance then UIManager:setDirty(Shelf.instance, "full") end
        end
        UIManager:close(dialog)
        UIManager:nextTick(function() self:showNavigationOrderDialog() end)
    end
    for index, tab in ipairs(order) do
        local saved_tab = tab
        buttons[#buttons + 1] = {
            { text=NAV_TAB_LABELS[saved_tab], callback=function() end },
            { text="↑", enabled=index > 1, callback=function() move(saved_tab, -1) end },
            { text="↓", enabled=index < #order, callback=function() move(saved_tab, 1) end },
        }
    end
    buttons[#buttons + 1] = {{ text="关闭", callback=function() UIManager:close(dialog) end }}
    dialog = ButtonDialog:new{
        title="导航顺序",
        title_align="center",
        width_factor=.72,
        buttons=buttons,
    }
    UIManager:show(dialog)
end

function Plugin:addToMainMenu(items)
    local navigation_items = {}
    for _, tab in ipairs(NAV_TABS) do
        local saved_tab = tab
        navigation_items[#navigation_items + 1] = {
            text=NAV_TAB_LABELS[tab],
            checked_func=function() return navigationTabEnabled(saved_tab) end,
            callback=function()
                local enabled = navigationTabEnabled(saved_tab)
                local count = 0
                for _, candidate in ipairs(NAV_TABS) do
                    if navigationTabEnabled(candidate) then count = count + 1 end
                end
                if enabled and count <= 1 then return end
                store:saveSetting("navigation_" .. saved_tab, not enabled)
                store:flush()
                if Shelf.instance and Shelf.instance.tab == saved_tab and not navigationTabEnabled(saved_tab) then
                    Shelf.instance:setTab(enabledNavigationTabs()[1])
                elseif Shelf.instance then
                    UIManager:setDirty(Shelf.instance, "full")
                end
            end,
        }
    end
    local open_mode_items = {
        {
            text="单击",
            checked_func=function() return globalSetting("book_open_mode") == "single" end,
            callback=function()
                saveGlobal("book_open_mode", "single")
                if Shelf.instance then Shelf.instance.disable_double_tap = true end
                if Device.input then Device.input.disable_double_tap = true end
            end,
        },
        {
            text="双击",
            checked_func=function() return globalSetting("book_open_mode") == "double" end,
            callback=function()
                saveGlobal("book_open_mode", "double")
                if Shelf.instance then Shelf.instance.disable_double_tap = false end
                if Device.input then Device.input.disable_double_tap = false end
            end,
        },
    }
    items.simplebookshelf = {
        text = "Reading Line",
        checked_func = pluginEnabled,
        sorting_hint = "tools",
        sub_item_table = {
            {text="导航栏", sub_item_table=navigation_items},
            {text="导航顺序", callback=function() self:showNavigationOrderDialog() end},
            {text="书本打开方式", sub_item_table=open_mode_items},
        },
        callback = function() self:toggleEnabled() end,
        -- Long-press follows the actual page state, not merely the persisted
        -- check mark: it opens a closed shelf and closes an open shelf.
        hold_callback = function(touchmenu_instance)
            local shelf = Shelf and Shelf.instance
            local is_open = shelf and UIManager:isWidgetShown(shelf)
            if touchmenu_instance and touchmenu_instance.closeMenu then
                touchmenu_instance:closeMenu()
            end
            if is_open then
                setPluginEnabled(false)
                UIManager:nextTick(function()
                    closeShelfInstance()
                    UIManager:nextTick(function()
                        UIManager:setDirty(nil, "full")
                    end)
                end)
            else
                setPluginEnabled(true)
                UIManager:nextTick(function()
                    self:showShelf(self:_resolveSuiPlugin(), true)
                end)
            end
            return true
        end,
    }
end
function Plugin:onCloseWidget()
    -- The page is never parked below ReaderUI now, so normal host cleanup is
    -- safe again and KOReader can drain its window stack when quitting.
    if applicationIsClosing() then
        closeShelfInstance()
        return
    end
    if self.ui and self.ui.tearing_down then return end
    closeShelfInstance()
end

return Plugin
