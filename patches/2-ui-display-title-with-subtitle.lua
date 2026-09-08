--[[
  2-ui-display-title-with-subtitle.lua

  Combines custom_props.subtitle into a "full title":
      Title: Subtitle   (or just Title when there is no subtitle)

  Requires 2-epub-extra-metadata.lua (subtitle already in custom_metadata.lua).

  Status bar:
    - "Book title" stays the regular title (never overwritten).
    - New item "Full title" can be enabled under Status bar → Configure items.
]]

local logger = require("logger")
local DocSettings = require("docsettings")
local filemanagerutil = require("apps/filemanager/filemanagerutil")
local gettext = require("gettext")
-- Do not bind gettext to `_`: `for _, i in ipairs` would shadow it and
-- turn `gettext("text")` into "attempt to call local '_' (a number value)".

-- =============================================================================
-- OPTIONS
-- =============================================================================
-- true  = inject the full title (Title: Subtitle) at that site
-- false = leave the regular title alone
local OPTIONS = {
    use_full_title_in_library     = true,  -- BookInfo / File Manager lists
    use_full_title_in_coverbrowser = true, -- CoverBrowser mosaic / list labels
    use_full_title_in_simpleui    = true,  -- SimpleUI homescreen (custom_props.title)
    -- Status bar "Book title" is never overwritten. Use the new "Full title" item instead.
}

local SEPARATOR = ": "

-- =============================================================================
-- Title helpers
-- =============================================================================

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
    if filepath then
        return filemanagerutil.splitFileNameType(filepath)
    end
    return ""
end

--- Persist combined string into custom_props.title (SimpleUI applyCustomProps).
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

--- Full title for display. persist_for_simpleui writes custom_props.title.
local function full_title_for(filepath, current_title, persist_for_simpleui)
    local sub, custom = subtitle_of(filepath)
    local plain = plain_title_of(filepath, current_title, custom)
    if not sub then
        return current_title or plain
    end
    local combined = combine(plain, sub)
    if persist_for_simpleui and custom.title ~= combined then
        pcall(persist_combined, filepath, plain, sub, combined)
    end
    return combined
end

-- =============================================================================
-- Vanilla BookInfo (library / Book information)
-- display_title is what the footer "Book title" item reads — keep it PLAIN.
-- =============================================================================

local BookInfo = require("apps/filemanager/filemanagerbookinfo")

local orig_extend = BookInfo.extendProps
function BookInfo.extendProps(original_props, filepath)
    local props = orig_extend(original_props, filepath)
    if props and filepath then
        -- Always restore a plain display_title so the status bar is not polluted
        local plain = plain_title_of(filepath, props.title, select(1, read_custom_props(filepath)))
        if plain and plain ~= "" then
            props.display_title = plain
        end
        if OPTIONS.use_full_title_in_library then
            props.full_title = full_title_for(filepath, props.title, false)
        end
    end
    return props
end

local orig_getDocProps = BookInfo.getDocProps
function BookInfo:getDocProps(file, book_props, no_open_document)
    local props = orig_getDocProps(self, file, book_props, no_open_document)
    if props and file then
        local plain = plain_title_of(file, props.title, select(1, read_custom_props(file)))
        if plain and plain ~= "" then
            props.display_title = plain
        end
        if OPTIONS.use_full_title_in_library then
            props.full_title = full_title_for(file, props.title, false)
        end
    end
    return props
end

-- =============================================================================
-- CoverBrowser
-- =============================================================================

local function patch_bim()
    if not OPTIONS.use_full_title_in_coverbrowser then return end
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
                bi.title = full_title_for(filepath, bi.title, false) or bi.title
            end
            return bi
        end
    end
    if BIM.getDocProps then
        local orig = BIM.getDocProps
        function BIM.getDocProps(self, filepath)
            local bi = orig(self, filepath)
            if bi and filepath then
                bi.title = full_title_for(filepath, bi.title, false) or bi.title
            end
            return bi
        end
    end
end
pcall(patch_bim)

-- =============================================================================
-- SimpleUI SH.getBookData
-- =============================================================================

local function patch_sh(mod, name)
    if not OPTIONS.use_full_title_in_simpleui then return false end
    if type(mod) ~= "table" or type(mod.getBookData) ~= "function" then return false end
    if mod._display_title_patched then return true end
    local orig = mod.getBookData
    mod.getBookData = function(filepath, prefetched, ...)
        local data = orig(filepath, prefetched, ...)
        if type(data) == "table" and type(filepath) == "string" then
            local combined = full_title_for(filepath, data.title, true)
            if combined and combined ~= "" then
                data.title = combined
            end
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
    if not OPTIONS.use_full_title_in_simpleui then return false end
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

-- =============================================================================
-- Status bar (bottom footer): keep Book title plain, add "Full title"
-- =============================================================================

local ReaderFooter = require("apps/reader/modules/readerfooter")

-- Make sure settings / generator map exist
ReaderFooter.default_settings = ReaderFooter.default_settings or {}
if ReaderFooter.default_settings.book_full_title == nil then
    ReaderFooter.default_settings.book_full_title = false
end
if ReaderFooter.default_settings.book_full_title_max_width_pct == nil then
    ReaderFooter.default_settings.book_full_title_max_width_pct =
        ReaderFooter.default_settings.book_title_max_width_pct or 30
end

-- Book title item: always the regular title (filename fallback via display_title/plain)
local orig_book_title_gen = ReaderFooter.textGeneratorMap and ReaderFooter.textGeneratorMap.book_title
if ReaderFooter.textGeneratorMap then
    ReaderFooter.textGeneratorMap.book_title = function(footer)
        local filepath = footer.ui and footer.ui.document and footer.ui.document.file
        local current = footer.ui and footer.ui.doc_props and
            (footer.ui.doc_props.title or footer.ui.doc_props.display_title)
        local text = plain_title_of(filepath, current)
        if (not text or text == "") and orig_book_title_gen then
            return orig_book_title_gen(footer)
        end
        return footer:getFittedText(text, footer.settings.book_title_max_width_pct)
    end

    ReaderFooter.textGeneratorMap.book_full_title = function(footer)
        local filepath = footer.ui and footer.ui.document and footer.ui.document.file
        local current = footer.ui and footer.ui.doc_props and
            (footer.ui.doc_props.title or footer.ui.doc_props.display_title)
        local text = full_title_for(filepath, current, false)
        return footer:getFittedText(text, footer.settings.book_full_title_max_width_pct
            or footer.settings.book_title_max_width_pct)
    end
end

local orig_textOptionTitles = ReaderFooter.textOptionTitles
function ReaderFooter:textOptionTitles(option)
    if option == "book_full_title" then
        return gettext("Full title")
    end
    return orig_textOptionTitles(self, option)
end

-- Include the new mode in the item order list used by "all at once" / arrange
local orig_set_mode_index = ReaderFooter.set_mode_index
function ReaderFooter:set_mode_index()
    orig_set_mode_index(self)
    local found, title_at = false, nil
    for i, name in ipairs(self.mode_index) do
        if name == "book_full_title" then found = true end
        if name == "book_title" then title_at = i end
    end
    if not found then
        local insert_at = title_at and (title_at + 1) or (#self.mode_index + 1)
        table.insert(self.mode_index, insert_at, "book_full_title")
        self.mode_nb = (self.mode_nb or #self.mode_index) + 1
        if self.mode_list then
            -- rebuild name → index
            for i = 0, #self.mode_index do
                if self.mode_index[i] then
                    self.mode_list[self.mode_index[i]] = i
                end
            end
        end
    end
end

local function item_label(item)
    if type(item) ~= "table" then return nil end
    if type(item.text) == "string" and item.text ~= "" then return item.text end
    if type(item.text_func) == "function" then
        local ok, label = pcall(item.text_func, item)
        if ok and type(label) == "string" then return label end
    end
    return nil
end

local function label_is(label, ...)
    if type(label) ~= "string" then return false end
    local low = label:lower()
    for i = 1, select("#", ...) do
        local want = select(i, ...)
        if want and (label == want or low:find(tostring(want):lower(), 1, true)) then
            return true
        end
    end
    return false
end

local function list_already_has_full_title(list)
    -- Only our injected Status-bar-items toggle.
    -- Arrange items also shows "Full title" via mode_index — ignore those.
    for _, item in ipairs(list) do
        if item and item._is_full_title_item then return true end
    end
    return false
end

local function make_full_title_toggle(footer)
    return {
        _is_full_title_item = true,
        text = gettext("Full title"),
        text_func = function()
            return gettext("Full title")
        end,
        help_text = gettext("Title: Subtitle when a subtitle exists, otherwise the regular title."),
        checked_func = function()
            return footer.settings and footer.settings.book_full_title == true
        end,
        callback = function()
            footer.settings.book_full_title = not footer.settings.book_full_title
            if footer.set_has_no_mode then pcall(footer.set_has_no_mode, footer) end
            if footer.updateFooterTextGenerator then pcall(footer.updateFooterTextGenerator, footer) end
            if footer.refreshFooter then
                pcall(footer.refreshFooter, footer, true)
            elseif footer.onUpdateFooter then
                pcall(footer.onUpdateFooter, footer, true)
            end
        end,
    }
end

-- getMinibarOption closes over `option`. Read that instead of the label.
local function closed_option(item)
    if type(item) ~= "table" then return nil end
    local fn = item.checked_func or item.text_func
    if type(fn) ~= "function" or not debug or not debug.getupvalue then return nil end
    local i = 1
    while true do
        local name, val = debug.getupvalue(fn, i)
        if not name then break end
        if name == "option" and type(val) == "string" then return val end
        i = i + 1
    end
    return nil
end

-- Insert Full title into the SAME array that holds Book title / Chapter title.
local function inject_into_item_list(list, footer)
    if type(list) ~= "table" or list_already_has_full_title(list) then
        return list_already_has_full_title(list)
    end
    local book_i, chapter_i, nested = nil, nil, 0
    for i, item in ipairs(list) do
        if item and (item.sub_item_table or item.sub_item_table_func) then
            nested = nested + 1
        end
        local opt = closed_option(item)
        local lab = item_label(item)
        if opt == "book_title" or label_is(lab, gettext("Book title"), "Book title") then
            book_i = i
        end
        if opt == "book_chapter" or label_is(lab, gettext("Chapter title"), "Chapter title") then
            chapter_i = i
        end
    end
    -- Parent Status bar menu has nested submenus; skip it.
    if nested > 0 then return false end
    if not book_i and not chapter_i then return false end
    local at = book_i and (book_i + 1) or chapter_i
    table.insert(list, at, make_full_title_toggle(footer))
    logger.info("display-title: inserted Full title into status bar items at", at,
        "book_i=", tostring(book_i), "chapter_i=", tostring(chapter_i))
    return true
end

local function wrap_sub_func(item, footer)
    if type(item) ~= "table" or type(item.sub_item_table_func) ~= "function" then return end
    if item._full_title_wrapped then return end
    local orig_fn = item.sub_item_table_func
    item.sub_item_table_func = function(...)
        local t = orig_fn(...)
        walk_menu_tree(t, footer, {})
        return t
    end
    item._full_title_wrapped = true
end

local walk_menu_tree
walk_menu_tree = function(node, footer, seen)
    if type(node) ~= "table" then return false end
    seen = seen or {}
    if seen[node] then return false end
    seen[node] = true

    local injected = inject_into_item_list(node, footer)

    for _, item in ipairs(node) do
        if type(item) == "table" then
            if type(item.sub_item_table) == "table" then
                if walk_menu_tree(item.sub_item_table, footer, seen) then
                    injected = true
                end
            end
            wrap_sub_func(item, footer)
        end
    end

    for k, v in pairs(node) do
        if type(k) == "string" and type(v) == "table" then
            if type(v.sub_item_table) == "table" then
                if walk_menu_tree(v.sub_item_table, footer, seen) then
                    injected = true
                end
            end
            wrap_sub_func(v, footer)
        end
    end
    return injected
end

local orig_addToMainMenu = ReaderFooter.addToMainMenu
function ReaderFooter:addToMainMenu(menu_items)
    orig_addToMainMenu(self, menu_items)
    logger.info("display-title: addToMainMenu, has status_bar=",
        menu_items and menu_items.status_bar ~= nil)
    local ok, inserted = pcall(walk_menu_tree, menu_items, self, {})
    if not ok then
        logger.warn("display-title: menu inject failed:", inserted)
    else
        logger.info("display-title: menu inject result=", tostring(inserted))
    end
end

-- Also wrap per-instance in case a later patch replaced the class method
local orig_footer_init = ReaderFooter.init
function ReaderFooter:init(...)
    orig_footer_init(self, ...)
    if self._full_title_instance_wrapped then return end
    self._full_title_instance_wrapped = true
    local inst_orig = self.addToMainMenu
    if type(inst_orig) == "function" then
        self.addToMainMenu = function(this, menu_items)
            inst_orig(this, menu_items)
            pcall(walk_menu_tree, menu_items, this, {})
        end
    end
end

-- Alt status bar (CRE header): add "Full title" next to "Book title"
-- Does not change window.status.title (regular Book title stays plain).
local function patch_alt_status_bar()
    local ok, ReaderCoptListener = pcall(require, "apps/reader/modules/readercoptlistener")
    if not ok or not ReaderCoptListener or not ReaderCoptListener.getAltStatusBarMenu then
        return
    end
    if ReaderCoptListener._full_title_alt_patched then return end
    ReaderCoptListener._full_title_alt_patched = true

    local orig_get = ReaderCoptListener.getAltStatusBarMenu
    function ReaderCoptListener:getAltStatusBarMenu()
        local menu = orig_get(self)
        local items = menu and menu.sub_item_table
        if not items then return menu end

        local function full_title_item()
            return {
                text = gettext("Full title"),
                help_text = gettext("Title: Subtitle when a subtitle exists, otherwise the regular title."),
                checked_func = function()
                    return G_reader_settings:isTrue("cre_header_full_title")
                end,
                callback = function()
                    local on = not G_reader_settings:isTrue("cre_header_full_title")
                    G_reader_settings:saveSetting("cre_header_full_title", on)
                    if on then
                        -- Show via additional header content; do not touch window.status.title
                        if not self._full_title_header_fn then
                            self._full_title_header_fn = function()
                                local filepath = self.ui and self.ui.document and self.ui.document.file
                                local current = self.ui and self.ui.doc_props and self.ui.doc_props.title
                                return full_title_for(filepath, current, false) or ""
                            end
                        end
                        local present = false
                        for _, fn in ipairs(self.additional_header_content or {}) do
                            if fn == self._full_title_header_fn then present = true break end
                        end
                        if not present and self.addAdditionalHeaderContent then
                            self:addAdditionalHeaderContent(self._full_title_header_fn)
                        end
                    else
                        if self._full_title_header_fn and self.removeAdditionalHeaderContent then
                            self:removeAdditionalHeaderContent(self._full_title_header_fn)
                        end
                    end
                    if self.updatePageInfoOverride then
                        self:updatePageInfoOverride()
                    end
                    if self.headerRefresh then
                        self:headerRefresh()
                    end
                end,
            }
        end

        local inserted = false
        for i, item in ipairs(items) do
            if item and item.text == gettext("Book title") then
                table.insert(items, i + 1, full_title_item())
                inserted = true
                break
            end
        end
        if not inserted then
            table.insert(items, full_title_item())
        end
        return menu
    end

    -- Restore additional content if the setting was already on
    local orig_read = ReaderCoptListener.onReadSettings
    function ReaderCoptListener:onReadSettings(config)
        orig_read(self, config)
        if G_reader_settings:isTrue("cre_header_full_title") then
            self._full_title_header_fn = self._full_title_header_fn or function()
                local filepath = self.ui and self.ui.document and self.ui.document.file
                local current = self.ui and self.ui.doc_props and self.ui.doc_props.title
                return full_title_for(filepath, current, false) or ""
            end
            if self.addAdditionalHeaderContent then
                self:addAdditionalHeaderContent(self._full_title_header_fn)
            end
            if self.updatePageInfoOverride then
                self:updatePageInfoOverride()
            end
        end
    end
end
pcall(patch_alt_status_bar)

-- =============================================================================
-- Delayed SimpleUI / CoverBrowser attach
-- =============================================================================

local userpatch = require("userpatch")
if userpatch.registerPatchPluginFunc then
    userpatch.registerPatchPluginFunc("coverbrowser", function()
        pcall(patch_bim)
    end)
    userpatch.registerPatchPluginFunc("simpleui", function()
        pcall(find_and_patch_simpleui)
        local UIManager = require("ui/uimanager")
        UIManager:nextTick(function()
            pcall(find_and_patch_simpleui)
        end)
        UIManager:scheduleIn(2, function()
            pcall(find_and_patch_simpleui)
        end)
    end)
end

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
