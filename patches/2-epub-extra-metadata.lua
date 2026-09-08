--[[
  2-epub-extra-metadata.lua

  Extracts from EPUB OPF (EPUB2 + EPUB3):
    - illustrator / translator (dc:creator & dc:contributor)
        * EPUB2: opf:role / role on the element
        * EPUB3: <meta refines="#id" property="role">trl|ill</meta>
    - subtitle (title-type, dc:subtitle, 2nd dc:title)

  Writes into book sidecar custom_metadata.lua → custom_props

  Folder open: only processes EPUBs with NO native sidecar; runs CoverBrowser
  extractBookInfo (native metadata) + this OPF parse.
]]

local logger = require("logger")
local DocSettings = require("docsettings")
local _ = require("gettext")

local EPUB_EXTS = { [".epub"] = true, [".kepub"] = true, [".kepub.epub"] = true }

local function is_epub(file)
    if not file then return false end
    local lower = file:lower()
    for ext in pairs(EPUB_EXTS) do
        if lower:sub(-#ext) == ext then return true end
    end
    return false
end

local function xml_attr(tag, name)
    return tag:match(name .. '%s*=%s*"([^"]*)"')
        or tag:match(name .. "%s*=%s*'([^']*)'")
end

local function extract_text(inner)
    if not inner then return "" end
    local text = inner:gsub("<[^>]+>", "")
    text = text:gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
    return text
end

local function normalize_role(role)
    if not role then return nil end
    role = role:lower():match("^%s*(.-)%s*$") or ""
    role = role:gsub("^marc:relators:", "")
    if role == "ill" or role == "illustrator" then return "illustrator" end
    if role == "trl" or role == "translator" then return "translator" end
    return nil
end

local function parse_opf_extra(opf)
    local out = { illustrators = {}, translators = {}, subtitle = nil }
    if not opf or opf == "" then return out end

    local people = {}
    local people_list = {}

    local function add_person(tag, rest, kind)
        local id = xml_attr(tag, "id")
        local name = extract_text(rest)
        if name == "" then return end
        local role_attr = normalize_role(xml_attr(tag, "opf:role") or xml_attr(tag, "role"))
        local person = { name = name, role = role_attr, kind = kind }
        table.insert(people_list, person)
        if id then people[id] = person end
    end

    for tag, rest in opf:gmatch("<(dc:creator[^>]*)>(.-)</dc:creator>") do
        add_person(tag, rest, "creator")
    end
    for tag, rest in opf:gmatch("<(dc:contributor[^>]*)>(.-)</dc:contributor>") do
        add_person(tag, rest, "contributor")
    end

    local function apply_role_refinement(refines, role_value)
        if not refines or not role_value then return end
        local id = refines:match("^#(.*)$") or refines
        local person = people[id]
        if not person then return end
        local role = normalize_role(role_value)
        if role then person.role = role end
    end

    for tag, rest in opf:gmatch("<(meta[^>]*)>(.-)</meta>") do
        local prop = (xml_attr(tag, "property") or ""):lower()
        if prop == "role" then
            apply_role_refinement(xml_attr(tag, "refines") or "", extract_text(rest))
        end
    end
    for tag in opf:gmatch("<meta[^>]+/?>") do
        local prop = (xml_attr(tag, "property") or xml_attr(tag, "name") or ""):lower()
        if prop == "role" then
            apply_role_refinement(xml_attr(tag, "refines") or "", xml_attr(tag, "content") or "")
        end
    end

    local seen = { illustrator = {}, translator = {} }
    for _, person in ipairs(people_list) do
        if person.role == "illustrator" or person.role == "translator" then
            local bucket = person.role == "illustrator" and out.illustrators or out.translators
            local key = person.name:lower()
            if not seen[person.role][key] then
                seen[person.role][key] = true
                table.insert(bucket, person.name)
            end
        end
    end

    -- subtitle
    local titles_by_id = {}
    for tag, rest in opf:gmatch("<(dc:title[^>]*)>(.-)</dc:title>") do
        local id = xml_attr(tag, "id")
        local text = extract_text(rest)
        if id and text ~= "" then titles_by_id[id] = text end
    end

    for tag, rest in opf:gmatch("<(meta[^>]*)>(.-)</meta>") do
        local prop = (xml_attr(tag, "property") or ""):lower()
        local refines = xml_attr(tag, "refines") or ""
        local content = extract_text(rest):lower()
        if prop == "title-type" and content == "subtitle" then
            local id = refines:match("^#(.*)$") or refines
            if id and titles_by_id[id] then
                out.subtitle = titles_by_id[id]
                break
            end
        end
    end
    if not out.subtitle then
        for tag in opf:gmatch("<meta[^>]+/?>") do
            local prop = (xml_attr(tag, "property") or xml_attr(tag, "name") or ""):lower()
            local refines = xml_attr(tag, "refines") or ""
            local content = (xml_attr(tag, "content") or ""):lower()
            if (prop == "title-type" or prop == "calibre:title_type") and content == "subtitle" then
                local id = refines:match("^#(.*)$") or refines
                if id and titles_by_id[id] then
                    out.subtitle = titles_by_id[id]
                    break
                end
            end
        end
    end
    if not out.subtitle then
        for rest in opf:gmatch("<dc:subtitle[^>]*>(.-)</dc:subtitle>") do
            local text = extract_text(rest)
            if text ~= "" then out.subtitle = text break end
        end
    end
    if not out.subtitle then
        for rest in opf:gmatch("<[%w%-]+:subtitle[^>]*>(.-)</[%w%-]+:subtitle>") do
            local text = extract_text(rest)
            if text ~= "" then out.subtitle = text break end
        end
    end
    if not out.subtitle then
        local count = 0
        for rest in opf:gmatch("<dc:title[^>]*>(.-)</dc:title>") do
            count = count + 1
            local text = extract_text(rest)
            if count == 2 and text ~= "" then
                out.subtitle = text
                break
            end
        end
    end

    return out
end

local function get_opf_from_epub(filepath)
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    if not reader:open(filepath) then
        logger.warn("epub-extra-metadata: archive open failed:", reader.err or filepath)
        return nil
    end

    local container_xml
    local opf_candidates = {}

    for entry in reader:iterate() do
        if entry.mode == "file" then
            local p = entry.path:gsub("\\", "/")
            if p == "META-INF/container.xml" or p:match("META%-INF/container%.xml$") then
                container_xml = reader:extractToMemory(entry.path)
            elseif p:lower():match("%.opf$") then
                table.insert(opf_candidates, entry.path)
            end
        end
    end

    local opf_path
    if container_xml then
        opf_path = container_xml:match('full%-path%s*=%s*"([^"]+)"')
                or container_xml:match("full%-path%s*=%s*'([^']+)'")
        if opf_path then
            opf_path = opf_path:gsub("^%./", ""):gsub("\\", "/")
        end
    end
    if not opf_path and #opf_candidates > 0 then
        opf_path = opf_candidates[1]
    end

    local opf
    if opf_path then
        opf = reader:extractToMemory(opf_path)
        if not opf then
            reader:close()
            reader = Archiver.Reader:new()
            if reader:open(filepath) then
                for _ in reader:iterate() do end
                opf = reader:extractToMemory(opf_path)
            end
        end
    end

    reader:close()
    return opf
end

local function save_extra_metadata(filepath, extra)
    if not extra then return end

    local custom_file = DocSettings:findCustomMetadataFile(filepath)
    local settings
    if custom_file then
        settings = DocSettings.openSettingsFile(custom_file)
    else
        settings = DocSettings.openSettingsFile()
    end
    if not settings then
        logger.warn("epub-extra-metadata: could not open settings for", filepath)
        return
    end

    local custom_props = settings:readSetting("custom_props") or {}

    if not settings:readSetting("doc_props") then
        local doc_settings = DocSettings:hasSidecarFile(filepath) and DocSettings:open(filepath)
        local doc_props = doc_settings and doc_settings:readSetting("doc_props") or {}
        settings:saveSetting("doc_props", doc_props)
    end

    if extra.subtitle and extra.subtitle ~= "" then
        custom_props.subtitle = extra.subtitle
    end
    if extra.illustrators and #extra.illustrators > 0 then
        custom_props.illustrator = table.concat(extra.illustrators, "; ")
        custom_props.illustrators = extra.illustrators
    end
    if extra.translators and #extra.translators > 0 then
        custom_props.translator = table.concat(extra.translators, "; ")
        custom_props.translators = extra.translators
    end
    -- Mark done even when OPF had no extra fields, so we do not re-parse forever
    custom_props._epub_extra_done = true

    settings:saveSetting("custom_props", custom_props)
    local ok = settings:flushCustomMetadata(filepath)
    if ok then
        logger.info("epub-extra-metadata: saved", filepath,
            "subtitle=", tostring(custom_props.subtitle),
            "translator=", tostring(custom_props.translator),
            "illustrator=", tostring(custom_props.illustrator))
    else
        logger.warn("epub-extra-metadata: flushCustomMetadata failed for", filepath)
    end
end

local function extract_and_cache(filepath)
    if not is_epub(filepath) then return end

    -- Skip re-parse if we already completed an extras pass
    local custom_file = DocSettings:findCustomMetadataFile(filepath)
    if custom_file then
        local s = DocSettings.openSettingsFile(custom_file)
        local c = s and s:readSetting("custom_props") or {}
        if c._epub_extra_done then
            return c
        end
    end

    local opf = get_opf_from_epub(filepath)
    if not opf then
        logger.warn("epub-extra-metadata: no OPF for", filepath)
        -- Still mark done so folder scan does not retry endlessly
        save_extra_metadata(filepath, { illustrators = {}, translators = {}, subtitle = nil })
        return
    end
    local extra = parse_opf_extra(opf)
    logger.info("epub-extra-metadata: parsed", filepath,
        "subtitle=", tostring(extra.subtitle),
        "translators=", #extra.translators,
        "illustrators=", #extra.illustrators)
    save_extra_metadata(filepath, extra)
    return extra
end

local function has_sidecar(filepath)
    return DocSettings:hasSidecarFile(filepath) and true or false
end

local function get_bookinfomanager()
    local ok, BIM = pcall(require, "bookinfomanager")
    if ok and BIM then return BIM end
    ok, BIM = pcall(require, "plugins/coverbrowser.koplugin/bookinfomanager")
    if ok and BIM then return BIM end
    return nil
end

--- Native CoverBrowser extract + our OPF extras. Only when no sidecar exists.
local function extract_full_if_no_sidecar(filepath)
    if not filepath or not is_epub(filepath) then return end
    if has_sidecar(filepath) then return end

    local BIM = get_bookinfomanager()
    if BIM and BIM.extractBookInfo then
        local ok = pcall(function()
            BIM:extractBookInfo(filepath)
        end)
        if not ok then
            pcall(function() BIM.extractBookInfo(BIM, filepath) end)
        end
    end

    pcall(extract_and_cache, filepath)
end

local function try_extract_if_needed(filepath)
    if not filepath or not is_epub(filepath) then return end
    if has_sidecar(filepath) then return end
    extract_full_if_no_sidecar(filepath)
end

-- ---------- BookInfo / CreDocument hooks ----------

local BookInfo = require("apps/filemanager/filemanagerbookinfo")
local orig_getDocProps = BookInfo.getDocProps
function BookInfo:getDocProps(file, book_props, no_open_document)
    local props = orig_getDocProps(self, file, book_props, no_open_document)
    if is_epub(file) then
        local ok, extra = pcall(extract_and_cache, file)
        if ok and extra then
            props = props or {}
            if extra.subtitle then props.subtitle = extra.subtitle end
            if extra.illustrators and #extra.illustrators > 0 then
                props.illustrator = table.concat(extra.illustrators, "; ")
            end
            if extra.translators and #extra.translators > 0 then
                props.translator = table.concat(extra.translators, "; ")
            end
        end
    end
    return props
end

local CreDocument = require("document/credocument")
local orig_getProps = CreDocument.getProps
function CreDocument:getProps()
    local props = orig_getProps(self)
    if self.file and is_epub(self.file) then
        local ok, extra = pcall(extract_and_cache, self.file)
        if ok and extra then
            if extra.subtitle then props.subtitle = extra.subtitle end
            if extra.illustrators and #extra.illustrators > 0 then
                props.illustrator = table.concat(extra.illustrators, "; ")
            end
            if extra.translators and #extra.translators > 0 then
                props.translator = table.concat(extra.translators, "; ")
            end
        end
    end
    return props
end

if BookInfo.props then
    local seen = {}
    for _, k in ipairs(BookInfo.props) do seen[k] = true end
    for _, k in ipairs({ "subtitle", "illustrator", "translator" }) do
        if not seen[k] then table.insert(BookInfo.props, k) end
    end
end
if BookInfo.prop_text then
    BookInfo.prop_text.subtitle = _("Subtitle:")
    BookInfo.prop_text.illustrator = _("Illustrator(s):")
    BookInfo.prop_text.translator = _("Translator(s):")
end

-- ---------- CoverBrowser hooks ----------

local function patch_bookinfomanager()
    local BookInfoManager = get_bookinfomanager()
    if not BookInfoManager then return end

    if BookInfoManager.getBookInfo then
        local orig = BookInfoManager.getBookInfo
        function BookInfoManager.getBookInfo(self, filepath, ...)
            local bookinfo = orig(self, filepath, ...)
            pcall(try_extract_if_needed, filepath)
            return bookinfo
        end
    end

    if BookInfoManager.extractBookInfo then
        local orig = BookInfoManager.extractBookInfo
        function BookInfoManager.extractBookInfo(self, filepath, ...)
            local ret = orig(self, filepath, ...)
            if filepath then
                pcall(extract_and_cache, filepath)
            end
            return ret
        end
    end
end
pcall(patch_bookinfomanager)

local userpatch = require("userpatch")
if userpatch.registerPatchPluginFunc then
    userpatch.registerPatchPluginFunc("coverbrowser", function()
        pcall(patch_bookinfomanager)
    end)
end

-- ---------- Folder open: only books with NO sidecar ----------

local SCAN_ON_FOLDER_OPEN = true
local SCAN_MAX_FILES = 40
local SCAN_YIELD_EVERY = 2

if SCAN_ON_FOLDER_OPEN then
    local FileManager = require("apps/filemanager/filemanager")
    local lfs = require("libs/libkoreader-lfs")

    local function scan_folder_no_sidecar(path)
        if not path or path == "" then return end

        local list = {}
        local ok, iter, dir_obj = pcall(lfs.dir, path)
        if not ok then return end
        for name in iter, dir_obj do
            if name ~= "." and name ~= ".." then
                local full = path .. "/" .. name
                local attr = lfs.attributes(full)
                if attr and attr.mode == "file" and is_epub(full) and not has_sidecar(full) then
                    table.insert(list, full)
                    if #list >= SCAN_MAX_FILES then break end
                end
            end
        end
        if #list == 0 then return end

        logger.info("epub-extra-metadata: folder scan", #list, "books without sidecar in", path)

        local UIManager = require("ui/uimanager")
        local i = 1

        local function step()
            if i > #list then
                logger.info("epub-extra-metadata: folder scan done")
                return
            end
            local fp = list[i]
            i = i + 1
            if not has_sidecar(fp) then
                extract_full_if_no_sidecar(fp)
            end
            if i <= #list then
                if (i % SCAN_YIELD_EVERY) == 0 then
                    UIManager:nextTick(step)
                else
                    step()
                end
            else
                logger.info("epub-extra-metadata: folder scan done")
            end
        end

        UIManager:nextTick(step)
    end

    if FileManager.showFiles and not FileManager._epub_extra_scan_hook then
        local orig_showFiles = FileManager.showFiles
        function FileManager.showFiles(path, ...)
            local ret = orig_showFiles(path, ...)
            local UIManager = require("ui/uimanager")
            UIManager:nextTick(function()
                pcall(scan_folder_no_sidecar, path)
            end)
            return ret
        end
        FileManager._epub_extra_scan_hook = true
    end
end

logger.info("epub-extra-metadata: patch loaded")