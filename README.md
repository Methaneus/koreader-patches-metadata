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
Only extracts from books without sidecar. Doesn't add to anything without any of the next patches. Can be expanded to extract more, if desired.
<br/><br/>

## 2-ui-display-title-with-subtitle.lua
**Requires 2-epub-extra-metadata.lua**<br/>
Patches native and SimpleUI views to use a display title combining the title with the previously extracted subtitle:
```
With:    Perfume: The Story of a Murderer
Without: American Psycho
```
<br/><br/>

## 2-ui-authors-with-roles.lua
**Requires 2-epub-extra-metadata.lua**<br/>
Does multiple things, each togglable in the patch by a boolean:
- Comma-separated authors: Authors are separated by a comma, instead of a newline. Only newlines when overflow is required for word-wrapping.
- Add contributors: Adds contributors previously extracted, with a suffix, to the author field. Boolean each for Translator and Illustrator.
