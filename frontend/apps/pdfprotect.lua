local BlitBuffer = require("ffi/blitbuffer")
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local C = ffi.C

local PdfProtect = {}

-- Default copyright settings
local DEFAULTS = {
    enabled = false,
    author = "Copyright Protected",
    rights = "All Rights Reserved",
    notice = "This document is protected by copyright. Unauthorized distribution is prohibited.",
    watermarks = false,   -- add visible watermark on each page
    stamp_page = 1,       -- page to stamp (0 = all pages)
}

--- Get the pdfprotect settings file path.
local function getSettingsPath()
    return DataStorage:getSettingsDir() .. "/pdfprotect.lua"
end

--- Read pdfprotect settings.
function PdfProtect:getSettings()
    local settings = LuaSettings:open(getSettingsPath())
    local saved = settings:readSetting("config") or {}
    -- Merge with defaults
    for k, v in pairs(DEFAULTS) do
        if saved[k] == nil then saved[k] = v end
    end
    return saved
end

--- Save pdfprotect settings.
function PdfProtect:saveSettings(config)
    local settings = LuaSettings:open(getSettingsPath())
    settings:saveSetting("config", config)
    settings:flush()
end

--- Embed copyright metadata into a PDF document's info dictionary.
-- Requires the document to be writable and opened by MuPDF.
-- Must be called before the document is closed (before writeDocument).
-- @param document PdfDocument instance (must be open)
-- @param config table with author, rights, notice fields
-- @return bool success
function PdfProtect:embedMetadata(document, config)
    if not document or not document._document then
        logger.warn("PdfProtect: no valid document")
        return false
    end
    if not document:_checkIfWritable() then
        logger.warn("PdfProtect: document is not writable")
        return false
    end

    config = config or self:getSettings()

    local ok, err = pcall(function()
        if config.author and config.author ~= "" then
            document._document:setMetadata("info:Author", config.author)
        end
        if config.rights and config.rights ~= "" then
            document._document:setMetadata("info:Rights", config.rights)
        end
        document._document:setMetadata("info:Copyright",
            string.format("%s | %s | %s",
                config.author or "",
                config.rights or "",
                os.date("%Y-%m-%d")))
        if config.notice and config.notice ~= "" then
            document._document:setMetadata("info:Subject", config.notice)
        end
        document.is_edited = true
    end)

    if ok then
        logger.info("PdfProtect: metadata embedded for", document.file)
        return true
    else
        logger.warn("PdfProtect: failed to embed metadata:", err)
        return false
    end
end

--- Add a visible copyright stamp annotation on a specific page.
-- Uses MuPDF's FreeText annotation to place visible copyright text.
-- @param document PdfDocument instance
-- @param pageno page number (1-based)
-- @param config table with notice, author fields
-- @return bool success
function PdfProtect:stampPage(document, pageno, config)
    if not document or not document._document then return false end
    if not document:_checkIfWritable() then return false end

    config = config or self:getSettings()

    local page = document._document:openPage(pageno)
    if not page then return false end

    -- Get page dimensions to position the stamp
    local pwidth, pheight = page:getSize(document.dc_null)
    if not pwidth or not pheight then
        page:close()
        return false
    end

    local ok, err = pcall(function()
        -- Create a highlight annotation at the bottom of the page as a copyright marker.
        -- The stamp text will be stored as the annotation contents.
        local stamp_text = config.notice or "Copyright Protected"
        if config.author and config.author ~= "" then
            stamp_text = stamp_text .. " - " .. config.author
        end

        local n = 2
        local points = ffi.new("fz_quad[?]", n)
        -- Bottom strip: 2 quad rectangles spanning page width
        local y0 = pheight - 30
        local y1 = pheight - 5
        points[0].ul.x = 10; points[0].ul.y = y0
        points[0].ur.x = pwidth / 2; points[0].ur.y = y0
        points[0].ll.x = 10; points[0].ll.y = y1
        points[0].lr.x = pwidth / 2; points[0].lr.y = y1

        points[1].ul.x = pwidth / 2 + 5; points[1].ul.y = y0
        points[1].ur.x = pwidth - 10; points[1].ur.y = y0
        points[1].ll.x = pwidth / 2 + 5; points[1].ll.y = y1
        points[1].lr.x = pwidth - 10; points[1].lr.y = y1

        local annot_color = BlitBuffer.colorFromName("gray")

        page:addMarkupAnnotation(points, n, C.PDF_ANNOT_HIGHLIGHT, annot_color)

        -- Get the annotation and set its contents to the copyright text
        local annot = page:getMarkupAnnotation(points, n)
        if annot ~= nil then
            page:updateMarkupAnnotation(annot, stamp_text)
        end

        document.is_edited = true
    end)

    page:close()

    if ok then
        logger.dbg("PdfProtect: stamped page", pageno, "of", document.file)
        return true
    else
        logger.warn("PdfProtect: failed to stamp page:", err)
        return false
    end
end

--- Stamp all pages with copyright information.
-- @param document PdfDocument instance
-- @param config table with copyright settings
-- @return number of pages stamped
function PdfProtect:stampAllPages(document, config)
    config = config or self:getSettings()
    if not config.watermarks then return 0 end

    local count = 0
    local total = document.info.number_of_pages or 0

    if config.stamp_page == 0 then
        -- Stamp all pages
        for pageno = 1, total do
            if self:stampPage(document, pageno, config) then
                count = count + 1
            end
        end
    elseif config.stamp_page <= total then
        -- Stamp a specific page
        if self:stampPage(document, config.stamp_page, config) then
            count = 1
        end
    end

    return count
end

--- Apply full copyright protection to a PDF document.
-- Embeds metadata and optionally stamps visible watermarks.
-- @param document PdfDocument instance
-- @param config optional config override
-- @return bool success
function PdfProtect:protect(document, config)
    if not document or not document.is_pdf then
        logger.warn("PdfProtect: only PDF documents are supported")
        return false
    end

    config = config or self:getSettings()
    if not config.enabled then return false end

    local meta_ok = self:embedMetadata(document, config)
    local stamped = self:stampAllPages(document, config)

    if meta_ok or stamped > 0 then
        UIManager:show(InfoMessage:new{
            text = _("Copyright protection applied to document."),
            timeout = 2,
        })
        return true
    end
    return false
end

--- Read copyright metadata from a PDF document.
-- @param document PdfDocument instance
-- @return table with author, rights, copyright, subject fields
function PdfProtect:readCopyright(document)
    if not document or not document._document then return nil end

    local metadata = document._document:getMetadata()
    if not metadata then return nil end

    -- Check for our copyright marker
    if not metadata.author or metadata.author == "" then
        return nil
    end

    return {
        author = metadata.author,
        rights = metadata.author,  -- stored in author field
        copyright = metadata.creationDate,
        notice = metadata.subject,
    }
end

--- Check if a document has copyright protection applied.
-- @param document PdfDocument instance
-- @return bool
function PdfProtect:isProtected(document)
    local info = self:readCopyright(document)
    return info ~= nil
end

--- Show copyright info dialog for a document.
-- @param document PdfDocument instance
function PdfProtect:showCopyrightInfo(document)
    local info = self:readCopyright(document)
    if not info then
        UIManager:show(InfoMessage:new{
            text = _("No copyright information found in this document."),
            timeout = 3,
        })
        return
    end

    UIManager:show(InfoMessage:new{
        text = require("ffi/util").template(_([[
Copyright Information

Author: %1
Rights: %2
Notice: %3]]),
            info.author or _("Unknown"),
            info.rights or _("Unknown"),
            info.notice or _("N/A")),
    })
end

--- Get a menu table for pdfprotect settings integration.
-- @return table of menu items
function PdfProtect:getSettingsMenuTable()
    local config = self:getSettings()

    return {
        {
            text = _("PDF Copyright Protection"),
            checked_func = function() return config.enabled end,
            callback = function()
                config.enabled = not config.enabled
                self:saveSettings(config)
            end,
        },
        {
            text = _("Copyright watermark on pages"),
            checked_func = function() return config.watermarks end,
            enabled_func = function() return config.enabled end,
            callback = function()
                config.watermarks = not config.watermarks
                self:saveSettings(config)
            end,
        },
    }
end

return PdfProtect
