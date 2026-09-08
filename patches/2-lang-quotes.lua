--[[
  2-lang-quotes.lua

  Enforce CSS quotation marks for <q> based on the EPUB language
  (dc:language / html lang / typography language tag).

  Edit QUOTE_STYLES below to add or change a language.
  Restart KOReader after editing.

  Example (German):
    <q>Hallo</q>  →  „Hallo“
  Example (British English):
    <q>Hello</q>  →  ‘Hello’
]]

local logger = require("logger")
local Event = require("ui/event")

-- =============================================================================
-- OPTIONS
-- =============================================================================

local OPTIONS = {
    enabled = true,

    -- If metadata has no language (or an unknown tag), use this style key
    -- (must exist in QUOTE_STYLES), or set to false to leave quotes alone.
    fallback_style = "en-US",

    -- Re-apply after typography has resolved the book language
    reapply_after_language = true,
}

-- =============================================================================
-- QUOTE STYLES (user-extendable)
-- =============================================================================
--
-- Each entry:
--   aliases  = extra language tags that should use this style
--              (the table key itself is always an alias)
--   primary  = { open, close }   outer <q>
--   nested   = { open, close }   <q> inside <q>  (optional; falls back to primary)
--
-- Tags are matched case-insensitively. "de-DE" matches style "de".
-- More specific keys win: "en-GB" is used before the generic "en" / "en-US".
--
-- Characters may be written as UTF-8 or as Lua hex escapes (\xE2\x80\x9C).

local QUOTE_STYLES = {
    -- American English: “…”  ‘…’
    ["en-US"] = {
        aliases = { "en", "eng", "en-us", "en-CA", "en-AU" },
        primary = { "\u{201C}", "\u{201D}" }, -- “ ”
        nested  = { "\u{2018}", "\u{2019}" }, -- ‘ ’
    },
    -- British English: ‘…’  “…”
    ["en-GB"] = {
        aliases = { "en-gb", "en-UK", "en-ie" },
        primary = { "\u{2018}", "\u{2019}" }, -- ‘ ’
        nested  = { "\u{201C}", "\u{201D}" }, -- “ ”
    },
    -- German (Germany / Austria): „…“  ‚…‘
    ["de"] = {
        aliases = { "deu", "ger", "de-DE", "de-AT", "de-de", "de-at" },
        primary = { "\u{201E}", "\u{201C}" }, -- „ “
        nested  = { "\u{201A}", "\u{2018}" }, -- ‚ ‘
    },
    -- Swiss German / Swiss French-style guillemets: «…»  ‹…›
    ["de-CH"] = {
        aliases = { "de-ch" },
        primary = { "\u{00AB}", "\u{00BB}" }, -- « »
        nested  = { "\u{2039}", "\u{203A}" }, -- ‹ ›
    },
    -- French: « … »  ‹ … ›
    -- (narrow no-break spaces are left to the publisher / other tweaks)
    ["fr"] = {
        aliases = { "fra", "fre", "fr-FR", "fr-BE", "fr-CA" },
        primary = { "\u{00AB}", "\u{00BB}" }, -- « »
        nested  = { "\u{2039}", "\u{203A}" }, -- ‹ ›
    },
    -- Spanish: «…»  “…”
    ["es"] = {
        aliases = { "spa", "es-ES", "es-MX", "es-AR" },
        primary = { "\u{00AB}", "\u{00BB}" },
        nested  = { "\u{201C}", "\u{201D}" },
    },
    -- Italian: «…»  “…”
    ["it"] = {
        aliases = { "ita", "it-IT" },
        primary = { "\u{00AB}", "\u{00BB}" },
        nested  = { "\u{201C}", "\u{201D}" },
    },
    -- Dutch: „…”  ‘…’
    ["nl"] = {
        aliases = { "nld", "dut", "nl-NL", "nl-BE" },
        primary = { "\u{201E}", "\u{201D}" }, -- „ ”
        nested  = { "\u{2018}", "\u{2019}" },
    },
    -- Russian / Ukrainian / Belarusian: «…»  „…“
    ["ru"] = {
        aliases = { "rus", "ru-RU", "uk", "ukr", "be", "bel" },
        primary = { "\u{00AB}", "\u{00BB}" },
        nested  = { "\u{201E}", "\u{201C}" },
    },
    -- Polish: „…”  «…»
    ["pl"] = {
        aliases = { "pol", "pl-PL" },
        primary = { "\u{201E}", "\u{201D}" },
        nested  = { "\u{00AB}", "\u{00BB}" },
    },
    -- Czech / Slovak: „…“  ‚…‘
    ["cs"] = {
        aliases = { "ces", "cze", "sk", "slk", "cs-CZ", "sk-SK" },
        primary = { "\u{201E}", "\u{201C}" },
        nested  = { "\u{201A}", "\u{2018}" },
    },
    -- Hungarian: „…”  »…«
    ["hu"] = {
        aliases = { "hun", "hu-HU" },
        primary = { "\u{201E}", "\u{201D}" },
        nested  = { "\u{00BB}", "\u{00AB}" },
    },
    -- Danish / Norwegian: »…«  ›…‹
    ["da"] = {
        aliases = { "dan", "no", "nor", "nb", "nn", "da-DK", "nb-NO" },
        primary = { "\u{00BB}", "\u{00AB}" },
        nested  = { "\u{203A}", "\u{2039}" },
    },
    -- Swedish / Finnish: ”…”  ’…’
    ["sv"] = {
        aliases = { "swe", "fi", "fin", "sv-SE", "fi-FI" },
        primary = { "\u{201D}", "\u{201D}" }, -- ” ”
        nested  = { "\u{2019}", "\u{2019}" },
    },
    -- Portuguese (Portugal): «…»  “…”
    ["pt"] = {
        aliases = { "por", "pt-PT" },
        primary = { "\u{00AB}", "\u{00BB}" },
        nested  = { "\u{201C}", "\u{201D}" },
    },
    -- Brazilian Portuguese: “…”  ‘…’
    ["pt-BR"] = {
        aliases = { "pt-br" },
        primary = { "\u{201C}", "\u{201D}" },
        nested  = { "\u{2018}", "\u{2019}" },
    },
    -- Japanese: 「…」  『…』
    ["ja"] = {
        aliases = { "jpn", "ja-JP" },
        primary = { "\u{300C}", "\u{300D}" }, -- 「 »
        nested  = { "\u{300E}", "\u{300F}" }, -- 『 』
    },
    -- Simplified Chinese: “…”  ‘…’
    ["zh"] = {
        aliases = { "zh-CN", "zh-Hans", "zh-SG" },
        primary = { "\u{201C}", "\u{201D}" },
        nested  = { "\u{2018}", "\u{2019}" },
    },
    -- Traditional Chinese: 「…」  『…』
    ["zh-Hant"] = {
        aliases = { "zh-TW", "zh-HK", "zh-MO", "zh-Hant-TW" },
        primary = { "\u{300C}", "\u{300D}" },
        nested  = { "\u{300E}", "\u{300F}" },
    },
}

-- =============================================================================
-- Implementation
-- =============================================================================

local function norm_tag(tag)
    if not tag or tag == "" then return nil end
    tag = tostring(tag):lower():gsub("_", "-"):gsub("%s+", "")
    -- "en-gb-oxendict" → keep looking from full tag down
    return tag
end

-- tag → style key, longest/most-specific first
local TAG_TO_STYLE = {}

local function register_style_key(tag, style_key)
    tag = norm_tag(tag)
    if tag then
        TAG_TO_STYLE[tag] = style_key
    end
end

for style_key, spec in pairs(QUOTE_STYLES) do
    register_style_key(style_key, style_key)
    if spec.aliases then
        for _, alias in ipairs(spec.aliases) do
            register_style_key(alias, style_key)
        end
    end
end

local function lookup_style_key(lang_tag)
    local tag = norm_tag(lang_tag)
    if not tag then return nil end
    -- Walk subtags: en-gb-oxendict → en-gb-oxendict, en-gb, en
    while tag do
        if TAG_TO_STYLE[tag] then
            return TAG_TO_STYLE[tag]
        end
        local shorter = tag:match("^(.*)%-[^-]+$")
        tag = shorter
    end
    return nil
end

local function css_escape_quote(s)
    -- Safe inside CSS double-quoted strings
    if not s then return "" end
    return (s:gsub("\\", "\\\\"):gsub('"', '\\"'))
end

local function build_quotes_css(style_key)
    local spec = QUOTE_STYLES[style_key]
    if not spec or not spec.primary then return nil end
    local p_open, p_close = spec.primary[1], spec.primary[2]
    local n_open, n_close
    if spec.nested then
        n_open, n_close = spec.nested[1], spec.nested[2]
    else
        n_open, n_close = p_open, p_close
    end

    -- quotes: property (if the engine honours it) + explicit ::before/::after
    -- so <q> still gets marks even when open-quote is unsupported.
    return string.format([[
/* lang-quotes: %s */
q {
    quotes: "%s" "%s" "%s" "%s" !important;
}
q:before, q::before {
    content: "%s" !important;
}
q:after, q::after {
    content: "%s" !important;
}
q q:before, q q::before {
    content: "%s" !important;
}
q q:after, q q::after {
    content: "%s" !important;
}
]],
        style_key,
        css_escape_quote(p_open), css_escape_quote(p_close),
        css_escape_quote(n_open), css_escape_quote(n_close),
        css_escape_quote(p_open),
        css_escape_quote(p_close),
        css_escape_quote(n_open),
        css_escape_quote(n_close))
end

local function document_language(ui)
    if not ui then return nil end
    -- Typography module already normalised dc:language / custom language
    if ui.typography then
        if ui.typography.book_lang_tag and ui.typography.book_lang_tag ~= "" then
            return ui.typography.book_lang_tag
        end
        if ui.typography.text_lang_tag and ui.typography.text_lang_tag ~= "" then
            return ui.typography.text_lang_tag
        end
    end
    if ui.document and ui.document.getProps then
        local ok, props = pcall(function() return ui.document:getProps() end)
        if ok and props then
            if props.language and props.language ~= "" then
                return props.language
            end
        end
    end
    -- Custom metadata language (Book information override)
    if ui.document and ui.document.file then
        local ok, BookInfo = pcall(require, "apps/filemanager/filemanagerbookinfo")
        if ok and BookInfo and BookInfo.getCustomProp then
            local lang = BookInfo.getCustomProp("language", ui.document.file)
            if lang and lang ~= "" then return lang end
        end
    end
    return nil
end

local function quotes_css_for_ui(ui)
    if not OPTIONS.enabled then return nil end
    local lang = document_language(ui)
    local style_key = lookup_style_key(lang)
    if not style_key then
        if OPTIONS.fallback_style and QUOTE_STYLES[OPTIONS.fallback_style] then
            style_key = OPTIONS.fallback_style
        else
            return nil
        end
    end
    logger.dbg("lang-quotes: lang=", tostring(lang), "style=", style_key)
    return build_quotes_css(style_key)
end

-- Append our CSS whenever style tweaks are collected
local ReaderStyleTweak = require("apps/reader/modules/readerstyletweak")
if ReaderStyleTweak and ReaderStyleTweak.getCssText
        and not ReaderStyleTweak._lang_quotes_patched then
    local orig_getCssText = ReaderStyleTweak.getCssText
    function ReaderStyleTweak:getCssText()
        local css = orig_getCssText(self) or ""
        local extra = quotes_css_for_ui(self.ui)
        if extra and extra ~= "" then
            if css ~= "" then
                return css .. "\n" .. extra
            end
            return extra
        end
        return css
    end
    ReaderStyleTweak._lang_quotes_patched = true
end

-- After the book language is resolved, rebuild + apply the stylesheet
if OPTIONS.reapply_after_language then
    local ok, ReaderTypography = pcall(require, "apps/reader/modules/readertypography")
    if ok and ReaderTypography and ReaderTypography.onPreRenderDocument
            and not ReaderTypography._lang_quotes_patched then
        local orig = ReaderTypography.onPreRenderDocument
        function ReaderTypography:onPreRenderDocument(...)
            local ret = orig(self, ...)
            if self.ui and self.ui.styletweak and self.ui.styletweak.updateCssText then
                -- Rebuild css_text (getCssText will include quotes) and apply
                pcall(function()
                    self.ui.styletweak:updateCssText(true)
                end)
            elseif self.ui then
                self.ui:handleEvent(Event:new("ApplyStyleSheet"))
            end
            return ret
        end
        ReaderTypography._lang_quotes_patched = true
    end
end

logger.info("lang-quotes: patch loaded")
