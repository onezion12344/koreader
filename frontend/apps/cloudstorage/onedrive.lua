local BD = require("ui/bidi")
local ConfirmBox = require("ui/widget/confirmbox")
local Device = require("device")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local OneDriveApi = require("apps/cloudstorage/onedriveapi")
local ReaderUI = require("apps/reader/readerui")
local UIManager = require("ui/uimanager")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local OneDrive = {}

--- Resolve an active access token from stored credentials.
-- If the access token is expired, tries to refresh it.
-- @param od_settings table with access_token, refresh_token, client_id, expires_at
-- @return string|nil access token, or nil on failure
function OneDrive:resolveAccessToken(od_settings)
    if od_settings.access_token then
        local now = os.time()
        if od_settings.expires_at and now < od_settings.expires_at - 60 then
            return od_settings.access_token
        end
    end
    if od_settings.refresh_token then
        local cid = od_settings.client_id
        local result = OneDriveApi:refreshAccessToken(od_settings.refresh_token, cid)
        if result and result.access_token then
            od_settings.access_token = result.access_token
            if result.refresh_token then
                od_settings.refresh_token = result.refresh_token
            end
            od_settings.expires_at = os.time() + (result.expires_in or 3600)
            return od_settings.access_token
        end
    end
end

function OneDrive:run(url, od_settings, choose_folder_mode)
    local token = self:resolveAccessToken(od_settings)
    if not token then
        return false, "Could not authenticate with OneDrive"
    end
    return OneDriveApi:listFolder(url, token, choose_folder_mode)
end

function OneDrive:showFiles(url, od_settings)
    local token = self:resolveAccessToken(od_settings)
    if not token then return {} end
    return OneDriveApi:showFiles(url, token)
end

function OneDrive:downloadFile(item, od_settings, path, callback_close, progress_callback)
    local token = self:resolveAccessToken(od_settings)
    if not token then
        UIManager:show(InfoMessage:new{
            text = _("Could not authenticate with OneDrive."),
            timeout = 3,
        })
        return
    end
    local code_response = OneDriveApi:downloadFile(item.url, token, path, progress_callback)
    if code_response == 200 then
        local __, filename = util.splitFilePathName(path)
        if G_reader_settings:isTrue("show_unsupported") and not DocumentRegistry:hasProvider(filename) then
            UIManager:show(InfoMessage:new{
                text = T(_("File saved to:\n%1"), BD.filename(path)),
            })
        else
            UIManager:show(ConfirmBox:new{
                text = T(_("File saved to:\n%1\nWould you like to read the downloaded book now?"),
                    BD.filepath(path)),
                ok_callback = function()
                    local Event = require("ui/event")
                    UIManager:broadcastEvent(Event:new("SetupShowReader"))
                    if callback_close then
                        callback_close()
                    end
                    ReaderUI:showReader(path)
                end
            })
        end
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Could not save file to:\n%1"), BD.filepath(path)),
            timeout = 3,
        })
    end
end

function OneDrive:downloadFileNoUI(url, od_settings, path)
    local token = self:resolveAccessToken(od_settings)
    if not token then return false end
    local code_response = OneDriveApi:downloadFile(url, token, path)
    return code_response == 200
end

function OneDrive:uploadFile(url, od_settings, file_path, callback_close)
    local token = self:resolveAccessToken(od_settings)
    if not token then
        UIManager:show(InfoMessage:new{
            text = _("Could not authenticate with OneDrive."),
            timeout = 3,
        })
        return
    end
    local code_response = OneDriveApi:uploadFile(url, token, file_path)
    local __, filename = util.splitFilePathName(file_path)
    if code_response >= 200 and code_response <= 299 then
        UIManager:show(InfoMessage:new{
            text = T(_("File uploaded:\n%1"), filename),
        })
        if callback_close then
            callback_close()
        end
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Could not upload file:\n%1"), filename),
        })
    end
end

function OneDrive:createFolder(url, od_settings, folder_name, callback_close)
    local token = self:resolveAccessToken(od_settings)
    if not token then return end
    local code_response = OneDriveApi:createFolder(url, token, folder_name)
    if code_response >= 200 and code_response <= 299 then
        if callback_close then
            callback_close()
        end
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Could not create folder:\n%1"), folder_name),
        })
    end
end

function OneDrive:config(item, callback)
    local text_name = item and item.text or nil

    self.settings_dialog = MultiInputDialog:new{
        title = _("OneDrive cloud storage"),
        fields = {
            {
                text = text_name,
                hint = _("Display name (optional)"),
            },
        },
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    self.settings_dialog:onClose()
                    UIManager:close(self.settings_dialog)
                end
            },
            {
                text = _("Sign in with Microsoft"),
                is_enter_default = true,
                callback = function()
                    local fields = self.settings_dialog:getFields()
                    local display_name = fields[1] ~= "" and fields[1] or _("OneDrive")
                    self.settings_dialog:onClose()
                    UIManager:close(self.settings_dialog)
                    self:_startDeviceAuth(display_name, item, callback)
                end
            },
        }},
    }
    UIManager:show(self.settings_dialog)
    self.settings_dialog:onShowKeyboard()
end

function OneDrive:_startDeviceAuth(display_name, existing_item, callback)
    local result = OneDriveApi:getDeviceCode()
    if not result or not result.device_code then
        UIManager:show(InfoMessage:new{
            text = _("Could not start authentication.\nPlease check your network connection."),
            timeout = 5,
        })
        return
    end

    local auth_url = result.verification_uri or "https://microsoft.com/devicelogin"
    local user_code = result.user_code
    local auth_link = auth_url .. "?code=" .. (user_code or "")

    local opened = false
    if Device:canOpenLink() then
        opened = Device:openLink(auth_link)
    end

    if opened then
        UIManager:show(InfoMessage:new{
            text = T(_([[
Browser opened for Microsoft sign-in.

If the code is not pre-filled, enter:
%1

Waiting for you to complete sign-in...]]), user_code),
            timeout = 30,
        })
    else
        UIManager:show(InfoMessage:new{
            text = T(_([[
To authorize OneDrive:

1. Open: %1
2. Code: %2

The code should be pre-filled. Sign in with your Microsoft account.]]), auth_link, user_code),
            timeout = 60,
        })
    end

    local device_code = result.device_code
    local interval = result.interval or 5
    local expires_at = os.time() + (result.expires_in or 900)

    local function doPoll()
        if os.time() >= expires_at then
            UIManager:show(InfoMessage:new{
                text = _("Authentication timed out.\nPlease try again."),
                timeout = 5,
            })
            return
        end

        local token_result = OneDriveApi:pollForToken(device_code)
        if token_result and token_result.access_token then
            local od_settings = {
                access_token = token_result.access_token,
                refresh_token = token_result.refresh_token,
                expires_at = os.time() + (token_result.expires_in or 3600),
            }
            local od_settings_json = require("json").encode(od_settings)

            if existing_item then
                callback(existing_item, {
                    display_name,
                    od_settings_json,
                    "",
                    existing_item.url or "/",
                })
            else
                callback({
                    display_name,
                    od_settings_json,
                    "",
                    "/",
                })
            end
            UIManager:show(InfoMessage:new{
                text = _("OneDrive connected successfully!"),
                timeout = 3,
            })
        elseif token_result and token_result.error == "authorization_pending" then
            UIManager:scheduleIn(interval, doPoll)
        else
            UIManager:show(InfoMessage:new{
                text = _("OneDrive authentication failed.\nPlease try again."),
                timeout = 5,
            })
        end
    end

    UIManager:scheduleIn(interval, doPoll)
end

function OneDrive:info(od_settings)
    local token = self:resolveAccessToken(od_settings)
    if not token then
        UIManager:show(InfoMessage:new{
            text = _("Could not authenticate with OneDrive."),
            timeout = 3,
        })
        return
    end
    local drive = OneDriveApi:fetchInfo(token)
    if drive then
        local owner = drive.owner and drive.owner.user and drive.owner.user.displayName or _("Unknown")
        local total = drive.quota and drive.quota.total or 0
        local used = drive.quota and drive.quota.used or 0
        local remaining = drive.quota and drive.quota.remaining or 0
        UIManager:show(InfoMessage:new{
            text = T(_("Type: OneDrive\nOwner: %1\nSpace total: %2\nSpace used: %3\nSpace free: %4"),
                owner,
                util.getFriendlySize(total),
                util.getFriendlySize(used),
                util.getFriendlySize(remaining)),
        })
    end
end

return OneDrive
