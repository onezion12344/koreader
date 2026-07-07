local DocumentRegistry = require("document/documentregistry")
local JSON = require("json")
local ffiUtil = require("ffi/util")
local http = require("socket.http")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local util = require("util")
local _ = require("gettext")

local OneDriveApi = {}

-- Microsoft OAuth2 endpoints
local OAUTH_DEVICECODE = "https://login.microsoftonline.com/common/oauth2/v2.0/devicecode"
local OAUTH_TOKEN      = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
local GRAPH_BASE       = "https://graph.microsoft.com/v1.0"

-- OneDrive scopes needed
local SCOPES = "Files.ReadWrite offline_access"

-- Default client ID for KOReader OneDrive integration.
local DEFAULT_CLIENT_ID = "80d04e6c-72b8-43db-a134-a5775cbe0c58"

local function resolveClientId(client_id)
    return client_id and client_id ~= "" and client_id or DEFAULT_CLIENT_ID
end

--- Get a device code for user authentication.
-- @param client_id optional Azure AD application client ID
-- @return table { device_code, user_code, verification_uri, message, expires_in }
function OneDriveApi:getDeviceCode(client_id)
    client_id = resolveClientId(client_id)
    local sink = {}
    local body = "client_id=" .. socket.url.escape(client_id)
        .. "&scope=" .. socket.url.escape(SCOPES)
    local request = {
        url     = OAUTH_DEVICECODE,
        method  = "POST",
        headers = {
            ["Content-Type"]   = "application/x-www-form-urlencoded",
            ["Content-Length"] = string.len(body),
        },
        source  = ltn12.source.string(body),
        sink    = ltn12.sink.table(sink),
    }
    socketutil:set_timeout()
    local code, _, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    local result_response = table.concat(sink)
    if code == 200 and result_response ~= "" then
        local _, result = pcall(JSON.decode, result_response)
        return result
    end
    logger.warn("OneDriveApi: cannot get device code:", status or code)
    logger.warn("OneDriveApi: error:", result_response)
end

--- Poll for access token after user completes device login.
-- @param device_code string from getDeviceCode
-- @param client_id optional Azure AD application client ID
-- @return table { access_token, refresh_token, expires_in }, or nil
function OneDriveApi:pollForToken(device_code, client_id)
    client_id = resolveClientId(client_id)
    local sink = {}
    local body = "grant_type=urn:ietf:params:oauth:grant-type:device_code"
        .. "&device_code=" .. socket.url.escape(device_code)
        .. "&client_id=" .. socket.url.escape(client_id)
    local request = {
        url     = OAUTH_TOKEN,
        method  = "POST",
        headers = {
            ["Content-Type"]   = "application/x-www-form-urlencoded",
            ["Content-Length"] = string.len(body),
        },
        source  = ltn12.source.string(body),
        sink    = ltn12.sink.table(sink),
    }
    socketutil:set_timeout()
    local code, _, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    local result_response = table.concat(sink)
    if code == 200 and result_response ~= "" then
        local _, result = pcall(JSON.decode, result_response)
        return result
    elseif code == 400 then
        local _, result = pcall(JSON.decode, result_response)
        if result and result.error == "authorization_pending" then
            return { error = "authorization_pending" }
        end
    end
    logger.warn("OneDriveApi: cannot get token:", status or code)
    logger.warn("OneDriveApi: error:", result_response)
end

--- Refresh an expired access token.
-- @param refresh_token string
-- @param client_id optional Azure AD application client ID
-- @return table { access_token, refresh_token, expires_in }, or nil
function OneDriveApi:refreshAccessToken(refresh_token, client_id)
    client_id = resolveClientId(client_id)
    local sink = {}
    local body = "grant_type=refresh_token"
        .. "&refresh_token=" .. socket.url.escape(refresh_token)
        .. "&client_id=" .. socket.url.escape(client_id)
    local request = {
        url     = OAUTH_TOKEN,
        method  = "POST",
        headers = {
            ["Content-Type"]   = "application/x-www-form-urlencoded",
            ["Content-Length"] = string.len(body),
        },
        source  = ltn12.source.string(body),
        sink    = ltn12.sink.table(sink),
    }
    socketutil:set_timeout()
    local code, _, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    local result_response = table.concat(sink)
    if code == 200 and result_response ~= "" then
        local _, result = pcall(JSON.decode, result_response)
        return result
    end
    logger.warn("OneDriveApi: cannot refresh token:", status or code)
    logger.warn("OneDriveApi: error:", result_response)
end

--- Build a Graph API path from a user-facing path.
-- "/" → "root:"  "/folder" → "root:/folder"
local function buildDrivePath(path)
    if path == nil or path == "" or path == "/" then
        return "root:"
    end
    -- Ensure path starts with /
    if not path:match("^/") then
        path = "/" .. path
    end
    return "root:" .. path
end

--- Fetch a page of children from a OneDrive folder.
-- @param raw_path user-facing path (e.g. "/Documents")
-- @param token access token
-- @param next_link optional @odata.nextLink for pagination
-- @return { entries, next_link } or nil
local function fetchChildrenPage(raw_path, token, next_link)
    local url
    if next_link then
        url = next_link
    else
        local drive_path = buildDrivePath(raw_path)
        url = GRAPH_BASE .. "/me/drive/" .. drive_path .. ":/children"
            .. "?$top=1000&$orderby=name"
    end
    local sink = {}
    local request = {
        url     = url,
        method  = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. token,
        },
        sink    = ltn12.sink.table(sink),
    }
    socketutil:set_timeout()
    local code, _, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    local result_response = table.concat(sink)
    if code == 200 and result_response ~= "" then
        local _, result = pcall(JSON.decode, result_response)
        return {
            entries = result.value,
            next_link = result["@odata.nextLink"],
        }
    end
    logger.warn("OneDriveApi: cannot list folder:", status or code)
    logger.warn("OneDriveApi: error:", result_response)
end

--- Fetch all children across pages.
local function fetchAllChildren(raw_path, token)
    local all_entries = {}
    local next_link = nil
    repeat
        local page = fetchChildrenPage(raw_path, token, next_link)
        if not page then
            return nil
        end
        for _, entry in ipairs(page.entries) do
            table.insert(all_entries, entry)
        end
        next_link = page.next_link
    until not next_link
    return all_entries
end

--- List folder contents, formatted for KOReader's cloud storage UI.
-- @param path user-facing path
-- @param token access token
-- @param folder_mode bool, true = show only folders + choose-folder helper
-- @return table of file/folder entries for KOReader menu
function OneDriveApi:listFolder(path, token, folder_mode)
    local entries = fetchAllChildren(path, token)
    if entries == nil then
        return false
    end

    local folder_list = {}
    local file_list = {}

    for _, item in ipairs(entries) do
        -- Skip deleted items if any
        if item.deleted then
            goto continue
        end

        local name = item.name
        local is_folder = item.folder ~= nil

        if is_folder then
            local entry = {
                text = name .. "/",
                url = item.id,
                type = folder_mode and "folder_long_press" or "folder",
                graph_id = item.id,
            }
            table.insert(folder_list, entry)
        elseif not folder_mode and (DocumentRegistry:hasProvider(name)
            or G_reader_settings:isTrue("show_unsupported")) then
            local entry = {
                text = name,
                mandatory = util.getFriendlySize(item.size),
                filesize = item.size,
                url = item.id,
                type = "file",
                graph_id = item.id,
                download_url = item["@microsoft.graph.downloadUrl"],
            }
            table.insert(file_list, entry)
        end
        ::continue::
    end

    -- Sort alphabetically
    table.sort(folder_list, function(v1, v2)
        return ffiUtil.strcoll(v1.text, v2.text)
    end)
    table.sort(file_list, function(v1, v2)
        return ffiUtil.strcoll(v1.text, v2.text)
    end)

    -- Add special folder-chooser entry
    if folder_mode then
        table.insert(folder_list, 1, {
            text = _("Long-press to choose current folder"),
            url = path,
            type = "folder_long_press",
        })
    end

    -- Folders first, then files
    for _, file in ipairs(file_list) do
        table.insert(folder_list, file)
    end

    return folder_list
end

--- Download a file from OneDrive by item ID.
-- @param item_id Graph item ID
-- @param token access token
-- @param local_path destination path on device
-- @param progress_callback optional function(total_bytes)
-- @return number HTTP status code
function OneDriveApi:downloadFile(item_id, token, local_path, progress_callback)
    local url = GRAPH_BASE .. "/me/drive/items/" .. item_id .. "/content"
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)

    local handle = ltn12.sink.file(io.open(local_path, "w"))
    if progress_callback then
        handle = socketutil.chainSinkWithProgressCallback(handle, progress_callback)
    end

    local code, _, status = socket.skip(1, http.request{
        url     = url,
        method  = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. token,
        },
        sink    = handle,
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        logger.warn("OneDriveApi: cannot download file:", status or code)
    end
    return code
end

--- Download a file by Graph path.
-- @param remote_path path like "/Documents/file.pdf"
-- @param token access token
-- @param local_path destination path
-- @param progress_callback optional
-- @return number HTTP status code
function OneDriveApi:downloadFileByPath(remote_path, token, local_path, progress_callback)
    local drive_path = buildDrivePath(remote_path)
    local url = GRAPH_BASE .. "/me/drive/" .. drive_path .. ":/content"
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)

    local handle = ltn12.sink.file(io.open(local_path, "w"))
    if progress_callback then
        handle = socketutil.chainSinkWithProgressCallback(handle, progress_callback)
    end

    local code, _, status = socket.skip(1, http.request{
        url     = url,
        method  = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. token,
        },
        sink    = handle,
    })
    socketutil:reset_timeout()
    if code ~= 200 then
        logger.warn("OneDriveApi: cannot download file by path:", status or code)
    end
    return code
end

--- Upload a file to OneDrive (small files < 4 MB, simple PUT).
-- @param remote_folder path like "/Documents"
-- @param token access token
-- @param file_path local file path to upload
-- @return number HTTP status code
function OneDriveApi:uploadFile(remote_folder, token, file_path)
    local filename = ffiUtil.basename(file_path)
    local folder = remote_folder
    if folder == "/" then folder = "" end
    local path_arg = folder .. "/" .. filename
    local drive_path = buildDrivePath(path_arg)
    local url = GRAPH_BASE .. "/me/drive/" .. drive_path .. ":/content"

    local file_size = lfs.attributes(file_path, "size")
    socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    local code, _, status = socket.skip(1, http.request{
        url     = url,
        method  = "PUT",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"]  = "application/octet-stream",
            ["Content-Length"] = file_size,
        },
        source  = ltn12.source.file(io.open(file_path, "r")),
    })
    socketutil:reset_timeout()
    if code < 200 or code > 299 then
        logger.warn("OneDriveApi: cannot upload file:", status or code)
    end
    return code
end

--- Create a folder in OneDrive.
-- @param remote_folder parent path like "/Documents"
-- @param token access token
-- @param folder_name new folder name
-- @return number HTTP status code
function OneDriveApi:createFolder(remote_folder, token, folder_name)
    local folder = remote_folder
    if folder == "/" then folder = "" end
    local drive_path = buildDrivePath(folder)
    local url = GRAPH_BASE .. "/me/drive/" .. drive_path .. ":/children"

    local body = JSON.encode({ name = folder_name, folder = {} })
    local code, _, status = socket.skip(1, http.request{
        url     = url,
        method  = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"]  = "application/json",
            ["Content-Length"] = string.len(body),
        },
        source  = ltn12.source.string(body),
    })
    socketutil:reset_timeout()
    if code < 200 or code > 299 then
        logger.warn("OneDriveApi: cannot create folder:", status or code)
    end
    return code
end

--- Fetch OneDrive account / drive info.
-- @param token access token
-- @return table with displayName, total, used, owner info
function OneDriveApi:fetchInfo(token)
    local sink = {}
    socketutil:set_timeout()
    local code, _, status = socket.skip(1, http.request{
        url     = GRAPH_BASE .. "/me/drive",
        method  = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. token,
        },
        sink    = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    local result_response = table.concat(sink)
    if code == 200 and result_response ~= "" then
        local _, result = pcall(JSON.decode, result_response)
        return result
    end
    logger.warn("OneDriveApi: cannot get drive info:", status or code)
    logger.warn("OneDriveApi: error:", result_response)
end

--- List only files (flat list with full paths) for sync operations.
-- @param folder_path path like "/Documents"
-- @param token access token
-- @return table of { text=filename, url=item_id, size=bytes }
function OneDriveApi:showFiles(folder_path, token)
    local entries = fetchAllChildren(folder_path, token)
    if entries == nil then return {} end

    local files = {}
    for _, item in ipairs(entries) do
        if item.deleted then goto continue end
        if item.file and (DocumentRegistry:hasProvider(item.name)
            or G_reader_settings:isTrue("show_unsupported")) then
            table.insert(files, {
                text = item.name,
                url = item.id,
                size = item.size,
            })
        end
        ::continue::
    end
    return files
end

return OneDriveApi
