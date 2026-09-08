--[[
  2-ui-authors-with-roles.lua

  Display authors with optional illustrators / translators.
  Book cards: comma-separated (wraps if the widget is too narrow).
  Author tab / metadata identity: one name per line so each person
  is a separate author, not one blob.

  Requires 2-epub-extra-metadata.lua (translator / illustrators in sidecar).
]]

local logger = require("logger")
local DocSettings = require("docsettings")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local gettext = require("gettext")

-- =============================================================================
-- OPTIONS
-- =============================================================================

local OPTIONS = {
    -- Book-card / list display: join names with ", " (widget wraps on overflow).
    -- Author-tab identity always uses newlines regardless of this flag.
    comma_separate_authors = true,

    -- Add extra contributor types. Add another row to extend.
    -- custom_keys: fields written by 2-epub-extra-metadata.lua
    roles = {
        {
            enabled     = true,
            id          = "illustrator",
            label       = gettext("Illustrator"),
            custom_keys = { "illustrators", "illustrator" },
        },
        {
            enabled     = true,
            id          = "translator",
            label       = gettext("Translator"),
            custom_keys = { "translators", "translator" },
        },
    },
}

-- =============================================================================
-- Sidecar helpers
-- =============================================================================

local function sidecar_paths(filepath)
    if not filepath then return nil, nil end
    local ok, dir, file = pcall(function()
        return filemanagerutil.getDefaultDir(), filepath
    end)
    local sdr = DocSettings:getSidecarDir(filepath)
    if not sdr then return nil, nil end
    return sdr .. "/custom_metadata.lua", sdr
end

local function open_custom(filepath)
    if not filepath then return nil end
    local ok, settings = pcall(function()
        if DocSettings.openCustomMetadata then
            return DocSettings:openCustomMetadata(filepath)
        end
        local path = DocSettings:getSidecarDir(filepath)
        if not path then return nil end
        local f = path .. "/custom_metadata.lua"
        if not require("lfs").attributes(f) then
            -- still open so we can write
        end
        return DocSettings:open(filepath)
    end)
    if ok then return settings end
    return nil
end

local function read_custom_props(filepath)
    local settings = DocSettings:open(filepath)
    if not settings then return {} end
    local custom = settings:readSetting("custom_props") or {}
    if not custom.subtitle and settings.readSetting then
        -- custom_metadata is a separate file on recent KOReader
        local ok, cs = pcall(function()
            if DocSettings.findCustomMetadataFile then
                local f = DocSettings:findCustomMetadataFile(filepath)
                if f and DocSettings.openSettingsFile then
                    return DocSettings.openSettingsFile(f)
                end
            end
        end)
        if ok and cs then
            custom = cs:readSetting("custom_props") or custom
        end
    end
    return custom
end

local function persist_custom(filepath, updates)
    if not filepath or not updates then return end
    local ok, settings = pcall(DocSettings.open, DocSettings, filepath)
    if not ok or not settings then return end
    local custom = settings:readSetting("custom_props") or {}
    -- Prefer dedicated custom metadata file
    if settings.flushCustomMetadata then
        for k, v in pairs(updates) do custom[k] = v end
        settings:saveSetting("custom_props", custom)
        pcall(settings.flushCustomMetadata, settings, filepath)
        return
    end
    for k, v in pairs(updates) do custom[k] = v end
    settings:saveSetting("custom_props", custom)
    pcall(settings.flush, settings)
end

-- =============================================================================
-- Name lists
-- =============================================================================

local function trim(s)
    return (tostring(s):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function word_count(s)
    local n = 0
    for _ in s:gmatch("%S+") do n = n + 1 end
    return n
end

-- Split one comma-delimited chunk into people.
-- "Jane Doe, John Smith"     → two authors (each token is "First Last")
-- "Doe, Jane"                → one author  (Last, First)
-- "Doe, Jane, Smith, John"   → two authors (Last, First pairs)
local function split_comma_names(chunk)
    local tokens = {}
    for t in (chunk .. ","):gmatch("(.-),") do
        t = trim(t)
        if t ~= "" then tokens[#tokens + 1] = t end
    end
    if #tokens <= 1 then
        return tokens
    end
    local multiword, single = 0, 0
    for _, t in ipairs(tokens) do
        if word_count(t) >= 2 then multiword = multiword + 1 else single = single + 1 end
    end
    if multiword == #tokens then
        return tokens
    end
    if single == #tokens and #tokens % 2 == 0 then
        local paired = {}
        for i = 1, #tokens, 2 do
            paired[#paired + 1] = tokens[i] .. ", " .. tokens[i + 1]
        end
        return paired
    end
    -- Mixed / ambiguous: keep as a single name
    return { chunk }
end

local function split_authors(s)
    if not s or s == "" then return {} end
    if type(s) == "table" then
        local out = {}
        for _, n in ipairs(s) do
            n = trim(n)
            if n ~= "" then out[#out + 1] = n end
        end
        return out
    end
    s = tostring(s):gsub("\r\n", "\n")
    local chunks = {}
    -- Hard separators first: newline, semicolon, " & ", " and "
    s = s:gsub("%s+[Aa][Nn][Dd]%s+", "\n")
    s = s:gsub("%s+&%s+", "\n")
    s = s:gsub(";", "\n")
    if s:find("\n", 1, true) then
        for chunk in (s .. "\n"):gmatch("(.-)\n") do
            chunk = trim(chunk)
            if chunk ~= "" then
                for _, n in ipairs(split_comma_names(chunk)) do
                    chunks[#chunks + 1] = n
                end
            end
        end
        return chunks
    end
    return split_comma_names(trim(s))
end

local function strip_role_suffix(name)
    return (name:gsub("%s*%(%s*[^)]+%)%s*$", ""))
end

local function list_from_custom(custom, keys)
    if not custom then return {} end
    local out = {}
    for _, key in ipairs(keys) do
        local v = custom[key]
        if type(v) == "table" then
            for _, n in ipairs(v) do
                n = tostring(n):gsub("^%s+", ""):gsub("%s+$", "")
                if n ~= "" then out[#out + 1] = n end
            end
        elseif type(v) == "string" and v ~= "" then
            for _, n in ipairs(split_authors(v)) do
                out[#out + 1] = n
            end
        end
        if #out > 0 then break end
    end
    return out
end

local function dedupe_append(dst, names, seen)
    for _, n in ipairs(names) do
        local key = n:lower()
        if not seen[key] then
            seen[key] = true
            dst[#dst + 1] = n
        end
    end
end

-- Identity list: one entry per person, authors first, then roles.
local function build_identity_list(filepath, authors)
    local custom = read_custom_props(filepath)
    local seen = {}
    local names = {}

    local plain = custom._plain_authors
    if (not plain or plain == "") and authors then
        -- First time: remember original authors without role suffixes
        plain = authors
    end
    for _, n in ipairs(split_authors(plain or authors or "")) do
        local core = strip_role_suffix(n)
        local key = core:lower()
        if not seen[key] then
            seen[key] = true
            names[#names + 1] = core
        end
    end

    for _, role in ipairs(OPTIONS.roles) do
        if role.enabled then
            for _, n in ipairs(list_from_custom(custom, role.custom_keys)) do
                local core = strip_role_suffix(n)
                local labelled = core .. " (" .. role.label .. ")"
                local key = core:lower()
                -- Same person already listed as author: keep the author entry,
                -- do not merge the role into that same string.
                if not seen[key] then
                    seen[key] = true
                    names[#names + 1] = labelled
                elseif seen[key] == true then
                    -- already an author; also add a distinct role entry
                    local rkey = labelled:lower()
                    if not seen[rkey] then
                        seen[rkey] = true
                        names[#names + 1] = labelled
                    end
                end
            end
        end
    end
    return names, custom, plain
end

local function join_display(names)
    if OPTIONS.comma_separate_authors then
        return table.concat(names, ", ")
    end
    return table.concat(names, "\n")
end

local function join_identity(names)
    -- Newline is what BookInfo, CoverBrowser and SimpleUI Author-browse split on.
    return table.concat(names, "\n")
end

-- Library > Authors reads CoverBrowser bookinfo.authors (SQLite), NOT the sidecar.
-- SimpleUI splits that column on "\n" only.
local function write_bookinfo_authors(filepath, identity)
    if not filepath or not identity then return end
    local ok, BIM = pcall(require, "apps/coverbrowser/bookinfomanager")
    if not ok or not BIM then return end
    if BIM.setBookInfoProperties then
        pcall(BIM.setBookInfoProperties, BIM, filepath, { authors = identity })
    end
end

local _applied = {} -- filepath → identity, skip repeat writes

local function apply_authors(filepath, authors)
    if not filepath then return authors end
    if _applied[filepath] then
        return _applied[filepath]
    end
    local names, custom, plain = build_identity_list(filepath, authors)
    if #names == 0 then return authors end
    local identity = join_identity(names)
    local display  = join_display(names)
    _applied[filepath] = identity
    if custom.authors ~= identity then
        persist_custom(filepath, {
            _plain_authors   = plain or custom._plain_authors or authors,
            authors          = identity,
            _authors_display = display,
        })
        write_bookinfo_authors(filepath, identity)
    elseif authors and authors ~= identity then
        write_bookinfo_authors(filepath, identity)
    end
    return identity
end

-- =============================================================================
-- BookInfo / CoverBrowser
-- =============================================================================

local ok_bi, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
if ok_bi and BookInfo then
    if BookInfo.extendProps and not BookInfo._authors_roles_patched then
        local orig = BookInfo.extendProps
        function BookInfo.extendProps(props, filepath)
            props = orig(props, filepath) or props or {}
            if filepath then
                props.authors = apply_authors(filepath, props.authors)
            end
            return props
        end
        BookInfo._authors_roles_patched = true
    end
    if BookInfo.getDocProps and not BookInfo._authors_roles_gdp then
        local orig = BookInfo.getDocProps
        function BookInfo.getDocProps(self, ...)
            local props = orig(self, ...)
            if type(props) == "table" then
                local fp = ...
                if type(fp) ~= "string" and self and self.file then fp = self.file end
                if type(fp) == "string" then
                    props.authors = apply_authors(fp, props.authors)
                end
            end
            return props
        end
        BookInfo._authors_roles_gdp = true
    end
end

local function patch_bim()
    local ok, BIM = pcall(require, "apps/coverbrowser/bookinfomanager")
    if not ok or not BIM or BIM._authors_roles_patched then return end
    BIM._authors_roles_patched = true
    if BIM.getBookInfo then
        local orig = BIM.getBookInfo
        function BIM:getBookInfo(filepath, ...)
            local info = orig(self, filepath, ...)
            if type(info) == "table" and filepath then
                info.authors = apply_authors(filepath, info.authors)
            end
            return info
        end
    end
    if BIM.getDocProps then
        local orig = BIM.getDocProps
        function BIM:getDocProps(filepath, ...)
            local props = orig(self, filepath, ...)
            if type(props) == "table" and filepath then
                props.authors = apply_authors(filepath, props.authors)
            end
            return props
        end
    end
end
pcall(patch_bim)
pcall(function()
    local userpatch = require("userpatch")
    if userpatch.registerPatchPluginFunc then
        userpatch.registerPatchPluginFunc("coverbrowser", patch_bim)
    end
end)

-- =============================================================================
-- SimpleUI: identity = newlines; card display can still use commas
-- =============================================================================

local function patch_metadata_source(mod, name)
    if type(mod) ~= "table" or not mod.getMatchingFiles or mod._authors_roles_ms then
        return
    end
    mod._authors_roles_ms = true
    local orig = mod.getMatchingFiles
    function mod.getMatchingFiles(...)
        local files = orig(...)
        if type(files) ~= "table" then return files end
        for _, row in ipairs(files) do
            local fp = row.fullpath or row.file or row.filepath
            if fp and row.authors then
                row.authors = apply_authors(fp, row.authors)
            end
        end
        return files
    end
    if mod.clearCache then pcall(mod.clearCache) end
    logger.info("authors-with-roles: patched getMatchingFiles in", tostring(name))
end

local function patch_simpleui()
    for name, mod in pairs(package.loaded) do
        if type(name) == "string" and type(mod) == "table" then
            if name:find("sui_metadata_source", 1, true)
                    or name:find("metadata_source", 1, true) then
                patch_metadata_source(mod, name)
            end
        end
        if type(name) == "string" and name:find("simpleui", 1, true)
                and type(mod) == "table" then
            local SH = mod
            if type(SH) == "table" and SH.getBookData and not SH._authors_roles_patched then
                local orig = SH.getBookData
                function SH.getBookData(...)
                    local data = orig(...)
                    if type(data) ~= "table" then return data end
                    local fp = data.file or data.filepath or data.path
                    if fp then
                        local identity = apply_authors(fp, data.authors)
                        data.authors = identity
                        -- Some SimpleUI list rows use authors as a single label.
                        -- Keep a comma form next to it; browse-by-author uses `authors`.
                        data.authors_display = join_display(split_authors(identity))
                    end
                    return data
                end
                SH._authors_roles_patched = true
                logger.info("authors-with-roles: patched getBookData in", name)
            end
        end
    end
    -- Named module used by current SimpleUI
    local ok, SH = pcall(require, "modules/module_books_shared")
    if not ok then
        ok, SH = pcall(require, "plugins/simpleui.koplugin/modules/module_books_shared")
    end
    if ok and type(SH) == "table" and SH.getBookData and not SH._authors_roles_patched then
        local orig = SH.getBookData
        function SH.getBookData(...)
            local data = orig(...)
            if type(data) ~= "table" then return data end
            local fp = data.file or data.filepath or data.path
            if fp then
                local identity = apply_authors(fp, data.authors)
                data.authors = identity
                data.authors_display = join_display(split_authors(identity))
            end
            return data
        end
        SH._authors_roles_patched = true
        logger.info("authors-with-roles: patched getBookData in modules/module_books_shared")
    end
    for _, req in ipairs({
        "features/library/sui_metadata_source",
        "plugins/simpleui.koplugin/features/library/sui_metadata_source",
    }) do
        local ok_ms, ms = pcall(require, req)
        if ok_ms then patch_metadata_source(ms, req) end
    end
end
pcall(patch_simpleui)

pcall(function()
    local FileManager = require("apps/filemanager/filemanager")
    if FileManager and FileManager.showFiles and not FileManager._authors_roles_fm then
        FileManager._authors_roles_fm = true
        local orig = FileManager.showFiles
        function FileManager:showFiles(...)
            pcall(patch_simpleui)
            return orig(self, ...)
        end
    end
end)

pcall(function()
    local userpatch = require("userpatch")
    if userpatch.registerPatchPluginFunc then
        userpatch.registerPatchPluginFunc("simpleui", patch_simpleui)
    end
end)

logger.info("authors-with-roles: patch loaded comma=",
    tostring(OPTIONS.comma_separate_authors), "roles= on")
