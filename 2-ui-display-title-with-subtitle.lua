--[[
  3-display-title-with-subtitle.lua

  Combines custom_props.subtitle into the visible title for:
    - SimpleUI (SH.getBookData — the real homescreen path)
    - Vanilla BookInfo display_title
    - CoverBrowser bookinfo.title

  Requires 2-epub-extra-metadata.lua (subtitle already in custom_metadata.lua).
]]

local logger = require("logger")
local DocSettings = require("docsettings")
local filemanagerutil = require("apps/filemanager/filemanagerutil")

local SEPARATOR = ": "

local function read_custom_props(filepath)
    if not filepath then return {} end
    local ok, custom_file = pcall(DocSettings.findCustomMetadataFile, DocSettings, filepath)
    if not ok or not custom_file then return {} end
    local ok2, settings = pcall(DocSettings.openSettingsFile, custom_file)
    if not ok2 or not settings then return {} end
    return settings:readSetting("custom_props") or {}, settings, custom_file
end

local function combine(title, subtitle)
    if not title or title == "" then return title or "" end
    if not subtitle or subtitle == "" then return title end
    local suffix = SEPARATOR .. subtitle
    if title:sub(-#suffix) == suffix then return title end
    -- already contains subtitle somewhere
    if title:lower():find(subtitle:lower(), 1, true) then return title end
    return title .. suffix
end

local function subtitle_of(filepath)
    local c = read_custom_props(filepath)
    local s = c.subtitle
    if type(s) == "string" then
        s = s:match("^%s*(.-)%s*$")
        if s ~= "" then return s, c end
    end
    return nil, c
end

local function plain_title_of(filepath, current_title, custom)
    custom = custom or select(1, read_custom_props(filepath))
    if custom._plain_title and custom._plain_title ~= "" then
        return custom._plain_title
    end
    local t = current_title
    local sub = custom.subtitle
    if t and sub and sub ~= "" then
        local suffix = SEPARATOR .. sub
        if t:sub(-#suffix) == suffix then
            t = t:sub(1, -#suffix - 1)
        end
    end
    if t and t ~= "" then return t end
    return filemanagerutil.splitFileNameType(filepath)
end

--- Write combined string into custom_props.title (SimpleUI applyCustomProps reads this).
local function persist_combined(filepath, plain, subtitle, combined)
    local custom, settings = read_custom_props(filepath)
    if not settings then
        settings = DocSettings.openSettingsFile()
        custom = {}
    end
    if not settings:readSetting("doc_props") then
        local ds = DocSettings:hasSidecarFile(filepath) and DocSettings:open(filepath)
        settings:saveSetting("doc_props", (ds and ds:readSetting("doc_props")) or { title = plain })
    end
    custom._plain_title = plain
    custom.subtitle = subtitle
    custom.title = combined
    settings:saveSetting("custom_props", custom)
    pcall(function() settings:flushCustomMetadata(filepath) end)
end

local function display_title_for(filepath, current_title)
    local sub, custom = subtitle_of(filepath)
    if not sub then return current_title end
    local plain = plain_title_of(filepath, current_title, custom)
    local combined = combine(plain, sub)
    -- Keep custom_props.title in sync for SimpleUI's applyCustomProps / cache
    if custom.title ~= combined then
        pcall(persist_combined, filepath, plain, sub, combined)
    end
    return combined
end

-- ===================== Vanilla BookInfo =====================
local BookInfo = require("apps/filemanager/filemanagerbookinfo")

local orig_extend = BookInfo.extendProps
function BookInfo.extendProps(original_props, filepath)
    local props = orig_extend(original_props, filepath)
    if props and filepath then
        local combined = display_title_for(filepath, props.title)
        if combined then
            props.display_title = combined
        end
    end
    return props
end

local orig_getDocProps = BookInfo.getDocProps
function BookInfo:getDocProps(file, book_props, no_open_document)
    local props = orig_getDocProps(self, file, book_props, no_open_document)
    if props and file then
        local combined = display_title_for(file, props.title)
        if combined then
            props.display_title = combined
        end
    end
    return props
end

-- ===================== CoverBrowser =====================
local function patch_bim()
    local ok, BIM = pcall(require, "bookinfomanager")
    if not ok then
        ok, BIM = pcall(require, "plugins/coverbrowser.koplugin/bookinfomanager")
    end
    if not ok or not BIM then return end
    if BIM.getBookInfo then
        local orig = BIM.getBookInfo
        function BIM.getBookInfo(self, filepath, ...)
            local bi = orig(self, filepath, ...)
            if bi and filepath then
                bi.title = display_title_for(filepath, bi.title) or bi.title
            end
            return bi
        end
    end
    if BIM.getDocProps then
        local orig = BIM.getDocProps
        function BIM.getDocProps(self, filepath)
            local bi = orig(self, filepath)
            if bi and filepath then
                bi.title = display_title_for(filepath, bi.title) or bi.title
            end
            return bi
        end
    end
end
pcall(patch_bim)

-- ===================== SimpleUI SH.getBookData =====================
local function patch_sh(mod, name)
    if type(mod) ~= "table" or type(mod.getBookData) ~= "function" then return false end
    if mod._display_title_patched then return true end
    local orig = mod.getBookData
    mod.getBookData = function(filepath, prefetched, ...)
        local data = orig(filepath, prefetched, ...)
        if type(data) == "table" and type(filepath) == "string" then
            local combined = display_title_for(filepath, data.title)
            if combined and combined ~= "" then
                data.title = combined
            end
            -- Drop SimpleUI's sidecar cache entry so next prefetch re-reads custom_props
            if mod.invalidateSidecarCache then
                pcall(mod.invalidateSidecarCache, filepath)
            end
        end
        return data
    end
    mod._display_title_patched = true
    logger.info("display-title: patched getBookData in", name or "?")
    return true
end

local function find_and_patch_simpleui()
    local patched = false
    -- Any already-loaded module whose name mentions books_shared
    for name, mod in pairs(package.loaded) do
        if type(name) == "string" and name:find("books_shared", 1, true) then
            if patch_sh(mod, name) then patched = true end
        end
    end
    -- Common require paths
    local tries = {
        "modules/module_books_shared",
        "plugins/simpleui.koplugin/modules/module_books_shared",
    }
    for _, path in ipairs(tries) do
        local ok, mod = pcall(require, path)
        if ok and patch_sh(mod, path) then patched = true end
    end
    -- PluginLoader instance (path may differ by install)
    pcall(function()
        local PluginLoader = require("pluginloader")
        local inst = PluginLoader:getPluginInstance("simpleui")
        if inst and inst.SH and patch_sh(inst.SH, "simpleui.SH") then
            patched = true
        end
    end)
    if not patched then
        logger.warn("display-title: SimpleUI module_books_shared not found yet")
    end
    return patched
end

pcall(find_and_patch_simpleui)

local userpatch = require("userpatch")
if userpatch.registerPatchPluginFunc then
    userpatch.registerPatchPluginFunc("coverbrowser", function()
        pcall(patch_bim)
    end)
    userpatch.registerPatchPluginFunc("simpleui", function()
        -- SimpleUI finishes loading modules after the plugin registers
        pcall(find_and_patch_simpleui)
        local UIManager = require("ui/uimanager")
        UIManager:nextTick(function()
            pcall(find_and_patch_simpleui)
        end)
        -- Retry a few seconds later in case modules load lazily
        UIManager:scheduleIn(2, function()
            pcall(find_and_patch_simpleui)
        end)
    end)
end

-- Also retry on first FileManager show (homescreen often builds after FM)
local FileManager = require("apps/filemanager/filemanager")
if FileManager and FileManager.showFiles and not FileManager._display_title_fm_hook then
    local orig = FileManager.showFiles
    function FileManager.showFiles(...)
        pcall(find_and_patch_simpleui)
        return orig(...)
    end
    FileManager._display_title_fm_hook = true
end

logger.info("display-title-with-subtitle: patch loaded")