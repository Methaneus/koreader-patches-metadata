--[[
  4-authors-with-roles.lua

  Configurable author display:
    - comma-separate multi-author lists (wrap by UI width)
    - optionally append role contributors (translator, illustrator, …)

  Edit the OPTIONS table below.
]]

local logger = require("logger")
local DocSettings = require("docsettings")

-- =============================================================================
-- OPTIONS (edit these)
-- =============================================================================

local OPTIONS = {
    -- Option 1:
    -- true  = multi-author lists use "A, B, C" (widgets wrap by width)
    -- false = leave author separators as stored (often newlines)
    comma_separate_authors = true,

    -- Options 2 / 3 / future roles:
    -- Each entry is appended after the plain authors, in this list order.
    --   enabled     – true/false
    --   singular    – custom_props key for a single string (e.g. "translator")
    --   plural      – custom_props key for a list (e.g. "translators")
    --   label       – suffix shown in parentheses
    --
    -- To add another contributor type later, copy a block and set keys/label.
    roles = {
        {
            enabled  = true,
            singular = "illustrator",
            plural   = "illustrators",
            label    = "Illustrator",
        },
        {
            enabled  = true,
            singular = "translator",
            plural   = "translators",
            label    = "Translator",
        },
        -- Example for a future role:
        -- {
        --     enabled  = false,
        --     singular = "editor",
        --     plural   = "editors",
        --     label    = "Editor",
        -- },
    },
}

-- =============================================================================
-- Implementation
-- =============================================================================

local function any_role_enabled()
    for _, role in ipairs(OPTIONS.roles) do
        if role.enabled then return true end
    end
    return false
end

local function read_custom(filepath)
    if not filepath then return {} end
    local ok, custom_file = pcall(DocSettings.findCustomMetadataFile, DocSettings, filepath)
    if not ok or not custom_file then return {} end
    local ok2, settings = pcall(DocSettings.openSettingsFile, custom_file)
    if not ok2 or not settings then return {} end
    return settings:readSetting("custom_props") or {}, settings
end

local function split_authors(authors)
    if not authors or authors == "" then return {} end
    local names, seen = {}, {}
    local normalized = authors
        :gsub("%s*;%s*", ",")
        :gsub("[\r\n]+", ",")
    for part in normalized:gmatch("[^,]+") do
        part = part:match("^%s*(.-)%s*$") or ""
        if part ~= "" then
            local key = part:lower()
            if not seen[key] then
                seen[key] = true
                table.insert(names, part)
            end
        end
    end
    return names
end

local function join_authors(names)
    if not names or #names == 0 then return "" end
    if OPTIONS.comma_separate_authors then
        return table.concat(names, ", ")
    end
    -- Preserve a newline-separated multi-author style when option 1 is off
    return table.concat(names, "\n")
end

local function list_from_custom(custom, singular, plural)
    local list, seen = {}, {}
    local function add(n)
        if type(n) ~= "string" then return end
        n = n:match("^%s*(.-)%s*$") or ""
        if n == "" then return end
        local key = n:lower()
        if seen[key] then return end
        seen[key] = true
        table.insert(list, n)
    end
    if type(custom[plural]) == "table" then
        for _, n in ipairs(custom[plural]) do add(n) end
    end
    if #list == 0 and type(custom[singular]) == "string" then
        for part in custom[singular]:gmatch("[^;]+") do
            add(part)
        end
    end
    return list
end

local function role_suffix_pattern(label)
    -- Match " (Label)" at end of a line/name
    return "%(" .. label:gsub("(%W)", "%%%1") .. "%)%s*$"
end

local function is_role_line(line)
    for _, role in ipairs(OPTIONS.roles) do
        if line:match(role_suffix_pattern(role.label)) then
            return true
        end
    end
    return false
end

local function plain_authors_list(authors, custom)
    if custom._plain_authors and custom._plain_authors ~= "" then
        return split_authors(custom._plain_authors)
    end
    local names = {}
    for _, line in ipairs(split_authors(authors)) do
        if not is_role_line(line) then
            table.insert(names, line)
        end
    end
    return names
end

local function needs_comma_normalize(authors)
    if not OPTIONS.comma_separate_authors then return false end
    if not authors or authors == "" then return false end
    if authors:find("\n") or authors:find("\r") or authors:find(";") then
        return true
    end
    return false
end

local function build_authors(filepath, authors)
    local custom = read_custom(filepath)
    local names = plain_authors_list(authors, custom)
    local present = {}
    for _, n in ipairs(names) do
        present[n:lower()] = true
    end

    for _, role in ipairs(OPTIONS.roles) do
        if role.enabled then
            local people = list_from_custom(custom, role.singular, role.plural)
            for _, name in ipairs(people) do
                local line = name .. " (" .. role.label .. ")"
                if not present[line:lower()] then
                    table.insert(names, line)
                    present[line:lower()] = true
                end
            end
        end
    end

    return join_authors(names)
end

local function persist_authors(filepath, combined, plain_joined)
    local custom, settings = read_custom(filepath)
    if not settings then
        settings = DocSettings.openSettingsFile()
        custom = {}
    end
    if not settings:readSetting("doc_props") then
        local ds = DocSettings:hasSidecarFile(filepath) and DocSettings:open(filepath)
        settings:saveSetting("doc_props", (ds and ds:readSetting("doc_props")) or {})
    end
    if plain_joined and plain_joined ~= "" then
        custom._plain_authors = plain_joined
    end
    custom.authors = combined
    settings:saveSetting("custom_props", custom)
    pcall(function() settings:flushCustomMetadata(filepath) end)
end

local function apply_authors(filepath, authors)
    if not filepath then return authors end

    local custom = read_custom(filepath)
    local roles_on = any_role_enabled()
    local has_role_data = false
    if roles_on then
        for _, role in ipairs(OPTIONS.roles) do
            if role.enabled then
                local people = list_from_custom(custom, role.singular, role.plural)
                if #people > 0 then
                    has_role_data = true
                    break
                end
            end
        end
    end

    local needs_norm = needs_comma_normalize(authors)
        or needs_comma_normalize(custom.authors)
        or needs_comma_normalize(custom._plain_authors)

    local plain_list = plain_authors_list(authors or custom.authors or "", custom)

    -- Multi-author comma normalize even without roles
    if OPTIONS.comma_separate_authors and #plain_list > 1 then
        needs_norm = true
    end

    if not has_role_data and not needs_norm then
        return authors
    end
    if #plain_list == 0 and not has_role_data then
        return authors
    end

    local plain_joined = join_authors(plain_list)
    local combined = build_authors(filepath, plain_joined)
    if combined and combined ~= "" and custom.authors ~= combined then
        pcall(persist_authors, filepath, combined, plain_joined)
    end
    return combined ~= "" and combined or authors
end

-- ---------- BookInfo ----------
local BookInfo = require("apps/filemanager/filemanagerbookinfo")

local orig_extendProps = BookInfo.extendProps
function BookInfo.extendProps(original_props, filepath)
    local props = orig_extendProps(original_props, filepath)
    if props and filepath then
        props.authors = apply_authors(filepath, props.authors)
    end
    return props
end

local orig_getDocProps = BookInfo.getDocProps
function BookInfo:getDocProps(file, book_props, no_open_document)
    local props = orig_getDocProps(self, file, book_props, no_open_document)
    if props and file then
        props.authors = apply_authors(file, props.authors)
    end
    return props
end

-- ---------- CoverBrowser ----------
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
                bi.authors = apply_authors(filepath, bi.authors)
            end
            return bi
        end
    end
    if BIM.getDocProps then
        local orig = BIM.getDocProps
        function BIM.getDocProps(self, filepath)
            local bi = orig(self, filepath)
            if bi and filepath then
                bi.authors = apply_authors(filepath, bi.authors)
            end
            return bi
        end
    end
end
pcall(patch_bim)

-- ---------- SimpleUI ----------
local function patch_sh(mod, name)
    if type(mod) ~= "table" or type(mod.getBookData) ~= "function" then return false end
    if mod._authors_roles_patched then return true end
    local orig = mod.getBookData
    mod.getBookData = function(filepath, prefetched, ...)
        local data = orig(filepath, prefetched, ...)
        if type(data) == "table" and type(filepath) == "string" then
            data.authors = apply_authors(filepath, data.authors) or data.authors
            if mod.invalidateSidecarCache then
                pcall(mod.invalidateSidecarCache, filepath)
            end
        end
        return data
    end
    mod._authors_roles_patched = true
    logger.info("authors-with-roles: patched getBookData in", name or "?")
    return true
end

local function find_and_patch_simpleui()
    local patched = false
    for name, mod in pairs(package.loaded) do
        if type(name) == "string" and name:find("books_shared", 1, true) then
            if patch_sh(mod, name) then patched = true end
        end
    end
    for _, path in ipairs({
        "modules/module_books_shared",
        "plugins/simpleui.koplugin/modules/module_books_shared",
    }) do
        local ok, mod = pcall(require, path)
        if ok and patch_sh(mod, path) then patched = true end
    end
    return patched
end
pcall(find_and_patch_simpleui)

local userpatch = require("userpatch")
if userpatch.registerPatchPluginFunc then
    userpatch.registerPatchPluginFunc("coverbrowser", function() pcall(patch_bim) end)
    userpatch.registerPatchPluginFunc("simpleui", function()
        pcall(find_and_patch_simpleui)
        local UIManager = require("ui/uimanager")
        UIManager:nextTick(function() pcall(find_and_patch_simpleui) end)
        UIManager:scheduleIn(2, function() pcall(find_and_patch_simpleui) end)
    end)
end

local FileManager = require("apps/filemanager/filemanager")
if FileManager and FileManager.showFiles and not FileManager._authors_roles_fm_hook then
    local orig = FileManager.showFiles
    function FileManager.showFiles(...)
        pcall(find_and_patch_simpleui)
        return orig(...)
    end
    FileManager._authors_roles_fm_hook = true
end

logger.info("authors-with-roles: patch loaded",
    "comma=", tostring(OPTIONS.comma_separate_authors),
    "roles=", any_role_enabled() and "on" or "off")