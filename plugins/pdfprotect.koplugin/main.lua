local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local Notification = require("ui/widget/notification")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")

local PdfProtect = require("apps/pdfprotect")

local PdfProtectPlugin = WidgetContainer:extend{
    name = "pdfprotect",
    is_doc_only = true,
}

function PdfProtectPlugin:init()
    self.config = PdfProtect:getSettings()
    self.ui.menu:registerToMainMenu(self)
end

function PdfProtectPlugin:addToMainMenu(menu_items)
    menu_items.pdf_copyright_protection = {
        text = _("PDF Copyright Protection"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text = _("Enable protection"),
                checked_func = function() return self.config.enabled end,
                callback = function()
                    self.config.enabled = not self.config.enabled
                    PdfProtect:saveSettings(self.config)
                end,
            },
            {
                text = _("Visible watermarks"),
                checked_func = function() return self.config.watermarks end,
                enabled_func = function() return self.config.enabled end,
                callback = function()
                    self.config.watermarks = not self.config.watermarks
                    PdfProtect:saveSettings(self.config)
                end,
            },
            {
                text = _("Copyright settings"),
                enabled_func = function() return self.config.enabled end,
                callback = function()
                    self:showSettingsDialog()
                end,
            },
            {
                text = _("Apply to current document"),
                enabled_func = function()
                    return self.ui.document and self.ui.document.is_pdf
                        and self.ui.document:_checkIfWritable()
                end,
                callback = function()
                    PdfProtect:protect(self.ui.document, self.config)
                end,
            },
            {
                text = _("View document copyright"),
                enabled_func = function()
                    return self.ui.document and self.ui.document.is_pdf
                end,
                callback = function()
                    PdfProtect:showCopyrightInfo(self.ui.document)
                end,
            },
        },
    }
end

function PdfProtectPlugin:showSettingsDialog()
    local dialog
    dialog = MultiInputDialog:new{
        title = _("Copyright Settings"),
        fields = {
            {
                text = self.config.author,
                hint = _("Author / copyright holder"),
            },
            {
                text = self.config.rights,
                hint = _("Rights (e.g. All Rights Reserved)"),
            },
            {
                text = self.config.notice,
                hint = _("Copyright notice text"),
            },
        },
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    dialog:onClose()
                    UIManager:close(dialog)
                end
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local fields = dialog:getFields()
                    self.config.author = fields[1]
                    self.config.rights = fields[2]
                    self.config.notice = fields[3]
                    PdfProtect:saveSettings(self.config)
                    dialog:onClose()
                    UIManager:close(dialog)
                    UIManager:show(Notification:new{
                        text = _("Copyright settings saved."),
                        timeout = 2,
                    })
                end
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Embed copyright metadata before the document is closed.
-- This fires before PdfDocument:close() → writeDocument().
function PdfProtectPlugin:onCloseDocument()
    if not self.config.enabled then return end
    local document = self.ui.document
    if not document or not document.is_pdf then return end
    if not document:_checkIfWritable() then return end

    -- Embed metadata (watermarks are only done on explicit "Apply" action)
    PdfProtect:embedMetadata(document, self.config)
end

return PdfProtectPlugin
