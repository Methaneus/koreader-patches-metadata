# koreader-patches-metadata
KOReader patches to read more metadata, and apply them to the relevant views. Compatible with SimpleUI.<br/>
AI-assisted coding.
<br/><br/>

## 2-epub-extra-metadata.lua
Extracts more metadata from epubs, and writes it to a custom file in the sidecar. Currently only extracts (because I only need/want) the following:
```
title type: subtitle
contributor types: translator, illustrator
```
Only extracts from books without sidecar, and because it reads _all_ metadata on opening a folder (otherwise, you'd have to open the book first before it'd extract), the first time it can be SLOW. Doesn't add to anything without any of the next patches. Can be expanded to extract more, if desired.
<br/><br/>

### 2-ui-display-title-with-subtitle.lua
**Requires 2-epub-extra-metadata.lua**<br/>
Patches native and SimpleUI views to use a display title (Full Title) combining the title with the previously extracted subtitle:
```
With:    Perfume: The Story of a Murderer
Without: American Psycho
```
Toggles in the patch to enable/disable (everything enabled by default) injection. Option in Status Bar config to add Full Title to the status bar.

### 2-ui-authors-with-roles.lua
**Requires 2-epub-extra-metadata.lua, if you use the extra contributors**<br/>
Does multiple things, each togglable in the patch by a boolean:
- Comma-separated authors: Authors are separated by a comma, instead of a newline. Only newlines when overflow is required for word-wrapping.
- Add contributors: Adds contributors previously extracted, with a suffix, to the author field. Boolean each for Translator and Illustrator.

## 2-lang-quotes.lua
User-configurable automatic quote-tag localization (including nested) based on epub's embedded language tag. Examples:
```
LANGUAGE TAG: QUOTE, NESTED QUOTE
en-US, en-CA, en-AU: “Hello” / nested ‘…’
en-GB: ‘Hello’ / nested “…”
de, de-DE „Hallo“ / nested ‚…‘
```
Includes configurable fallback-style (default en-US). Matched case-insensitively, more specific keys win (en-GB > en).

# Screenshots
### 2-ui-authors-with-roles.lua _with_ 2-ui-display-title-with-subtitle.lua
#### Commas:
<img src="/screenshots/comma%201.png" width="25%"/> <img src="/screenshots/comma%202.png" width="25%"/>

#### Newlines:
<img src="/screenshots/newline%201.png" width="25%"/> <img src="/screenshots/newline%202.png" width="25%"/>
