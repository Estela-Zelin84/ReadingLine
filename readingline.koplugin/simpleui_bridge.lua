-- Shared SimpleUI bridge for bookshelf plugins.
--
-- The bridge is deliberately small: it owns only module resolution and the
-- public navbar/action hand-off.  It prefers the 2.5.x module layout and
-- falls back to the 2.1.x layout, so plugin feature code never mixes the two
-- module registries in one process.

local M = {}
local cached

local function first(modern, legacy)
    local ok, value = pcall(require, modern)
    if ok and value then return value end
    local ok_old, value_old = pcall(require, legacy)
    if ok_old and value_old then return value_old end
    return nil
end

function M.resolve()
    if cached then return cached end
    local modules = {
        UI = first("infra/sui_core", "sui_core"),
        Config = first("infra/sui_config", "sui_config"),
        Store = first("infra/sui_store", "sui_store"),
        Actions = first("features/sui_quickactions", "sui_quickactions"),
        Bottombar = first("screens/sui_bottombar", "sui_bottombar"),
        Style = first("features/sui_style", "sui_style"),
    }
    if not (modules.UI and modules.Config and modules.Store and modules.Actions) then
        return nil
    end
    cached = modules
    return cached
end

function M.registerAction(descriptor)
    local modules = M.resolve()
    if not modules or not descriptor or not descriptor.id then return false end
    local config = modules.Config
    if not config.ACTION_BY_ID[descriptor.id] then
        config.ALL_ACTIONS[#config.ALL_ACTIONS + 1] = descriptor
        config.ACTION_BY_ID[descriptor.id] = descriptor
    end
    if modules.Actions.register then modules.Actions.register(descriptor) end
    return true
end

function M.invalidateTabsCache()
    local modules = M.resolve()
    if modules and modules.Config.invalidateTabsCache then
        modules.Config.invalidateTabsCache()
    end
end

function M.rawTabs()
    local modules = M.resolve()
    if not modules or type(modules.Store.get) ~= "function" then return nil end
    local tabs = modules.Store:get("simpleui_bar_tabs")
    return type(tabs) == "table" and tabs or nil
end

function M.isTabConfigComplete()
    local modules = M.resolve()
    local raw = M.rawTabs()
    if not modules or not raw then return true end
    for _, id in ipairs(raw) do
        local known = modules.Config.ACTION_BY_ID[id]
        if not known and modules.Actions.isRegistered then
            known = modules.Actions.isRegistered(id)
        end
        if not known and not (type(id) == "string" and id:match("^custom_qa_%d+$")) then
            return false
        end
    end
    return true
end

function M.loadTabs()
    local modules = M.resolve()
    if not modules then return nil end
    return modules.Config.loadTabConfig()
end

function M.saveTabs(tabs)
    local modules = M.resolve()
    if not modules or type(tabs) ~= "table" then return false end
    if not M.isTabConfigComplete() then return false end
    modules.Config.saveTabConfig(tabs)
    return true
end

function M.wrapWithNavbar(inner, active_id, tabs)
    local modules = M.resolve()
    if not modules or not modules.UI.wrapWithNavbar then return nil end
    return modules.UI.wrapWithNavbar(inner, active_id, tabs)
end

function M.applyNavbarState(widget, container, bar, topbar, bar_index,
                            topbar_on, topbar_index, tabs)
    local modules = M.resolve()
    if not modules or not modules.UI.applyNavbarState then return false end
    modules.UI.applyNavbarState(widget, container, bar, topbar, bar_index,
        topbar_on, topbar_index, tabs)
    return true
end

function M.rebuildNavbars(plugin)
    local modules = M.resolve()
    if not modules or not modules.Bottombar
            or not modules.Bottombar.rebuildAllNavbars or not plugin then
        return false
    end
    pcall(modules.Bottombar.rebuildAllNavbars, plugin)
    return true
end

return M
