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
-- Register your own at https://portal.azure.com for production use.
local DEFAULT_CLIENT_ID = "80d04e6c-72b8-43db-a134-a5775cbe0c58"

-- Resolve client_id from parameter or default.
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

--- Delete a file or folder by path.
-- @param path user-facing path (e.g. "/Documents/book.pdf")
-- @param token access token
-- @return number HTTP status code
function OneDriveApi:deleteItem(path, token)
    local drive_path = buildDrivePath(path)
    local url = GRAPH_BASE .. "/me/drive/" .. drive_path
    socketutil:set_timeout()
    local code, _, status = socket.skip(1, http.request{
        url     = url,
        method  = "DELETE",
        headers = {
            ["Authorization"] = "Bearer " .. token,
        },
    })
    socketutil:reset_timeout()
    if code < 200 or code > 299 then
        logger.warn("OneDriveApi: cannot delete item:", status or code)
    end
    return code
end

--- Rename a file or folder.
-- @param path user-facing path (e.g. "/Documents/old.pdf")
-- @param token access token
-- @param new_name new name for the item
-- @return table|nil updated item metadata, or nil on failure
function OneDriveApi:renameItem(path, token, new_name)
    local drive_path = buildDrivePath(path)
    local url = GRAPH_BASE .. "/me/drive/" .. drive_path
    local body = JSON.encode({ name = new_name })
    local sink = {}
    socketutil:set_timeout()
    local code, _, status = socket.skip(1, http.request{
        url     = url,
        method  = "PATCH",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"]  = "application/json",
            ["Content-Length"] = string.len(body),
        },
        source  = ltn12.source.string(body),
        sink    = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if code == 200 then
        local _, result = pcall(JSON.decode, table.concat(sink))
        return result
    end
    logger.warn("OneDriveApi: cannot rename item:", status or code)
end

--- Move a file or folder to a new parent folder.
-- @param path user-facing source path (e.g. "/Documents/book.pdf")
-- @param token access token
-- @param new_parent_path destination folder path (e.g. "/Archive")
-- @return table|nil updated item metadata, or nil on failure
function OneDriveApi:moveItem(path, token, new_parent_path)
    local item_drive_path = buildDrivePath(path)
    local url = GRAPH_BASE .. "/me/drive/" .. item_drive_path
    local parent_ref = buildDrivePath(new_parent_path)
    local body = JSON.encode({ parentReference = { path = "/drive/" .. parent_ref } })
    local sink = {}
    socketutil:set_timeout()
    local code, _, status = socket.skip(1, http.request{
        url     = url,
        method  = "PATCH",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"]  = "application/json",
            ["Content-Length"] = string.len(body),
        },
        source  = ltn12.source.string(body),
        sink    = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if code == 200 then
        local _, result = pcall(JSON.decode, table.concat(sink))
        return result
    end
    logger.warn("OneDriveApi: cannot move item:", status or code)
end

--- Copy a file or folder.
-- @param path user-facing source path
-- @param token access token
-- @param new_parent_path destination folder path
-- @param new_name optional new name for the copy
-- @return string|nil URL to monitor async copy progress, or nil on failure
function OneDriveApi:copyItem(path, token, new_parent_path, new_name)
    local item_drive_path = buildDrivePath(path)
    local url = GRAPH_BASE .. "/me/drive/" .. item_drive_path .. ":/copy"
    local parent_ref = buildDrivePath(new_parent_path)
    local req_body = { parentReference = { path = "/drive/" .. parent_ref } }
    if new_name then req_body.name = new_name end
    local body = JSON.encode(req_body)
    local sink = {}
    socketutil:set_timeout()
    local code, _, status = socket.skip(1, http.request{
        url     = url,
        method  = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"]  = "application/json",
            ["Content-Length"] = string.len(body),
        },
        source  = ltn12.source.string(body),
        sink    = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if code == 202 then
        -- Returns a Location header for monitoring progress
        local _, result = pcall(JSON.decode, table.concat(sink))
        return result and result.location
    end
    logger.warn("OneDriveApi: cannot copy item:", status or code)
end

--- Search files and folders by name query.
-- @param query search string (matches file/folder names)
-- @param token access token
-- @return table|nil list of matching items
function OneDriveApi:searchFiles(query, token)
    if not query or query == "" then return {} end
    local all_results = {}
    local next_link = GRAPH_BASE .. "/me/drive/root/search(q='" .. socket.url.escape(query) .. "')?$top=500"
    while next_link do
        local sink = {}
        socketutil:set_timeout()
        local code, _, status = socket.skip(1, http.request{
            url     = next_link,
            method  = "GET",
            headers = {
                ["Authorization"] = "Bearer " .. token,
            },
            sink    = ltn12.sink.table(sink),
        })
        socketutil:reset_timeout()
        if code == 200 then
            local _, result = pcall(JSON.decode, table.concat(sink))
            if result and result.value then
                for _, item in ipairs(result.value) do
                    table.insert(all_results, item)
                end
            end
            next_link = result and result["@odata.nextLink"]
            if next_link then
                -- Graph returns nextLink with single-quoted query; needs escaping
                next_link = next_link:gsub("'", "''")
            end
        else
            logger.warn("OneDriveApi: search failed:", status or code)
            break
        end
    end
    return all_results
end

--- Get incremental changes since last sync (delta API).
-- @param token access token
-- @param delta_link optional deltaLink from previous call for incremental results
-- @return table { entries, delta_link, reset_link }
function OneDriveApi:getDelta(token, delta_link)
    local url = delta_link or (GRAPH_BASE .. "/me/drive/root/delta?$top=500")
    local all_entries = {}
    local current_link = url
    while current_link do
        local sink = {}
        socketutil:set_timeout()
        local code, _, status = socket.skip(1, http.request{
            url     = current_link,
            method  = "GET",
            headers = {
                ["Authorization"] = "Bearer " .. token,
            },
            sink    = ltn12.sink.table(sink),
        })
        socketutil:reset_timeout()
        if code == 200 then
            local _, result = pcall(JSON.decode, table.concat(sink))
            if result and result.value then
                for _, item in ipairs(result.value) do
                    table.insert(all_entries, item)
                end
            end
            current_link = result and result["@odata.nextLink"]
            if result and result["@odata.deltaLink"] then
                return {
                    entries = all_entries,
                    delta_link = result["@odata.deltaLink"],
                    reset_link = result["@odata.nextLink"],
                }
            end
        else
            logger.warn("OneDriveApi: delta query failed:", status or code)
            break
        end
    end
end

--- Create a sharing link for a file or folder.
-- @param path user-facing path
-- @param token access token
-- @param link_type "view" (default), "edit", or "embed"
-- @return table|nil { link, type, webUrl }, or nil on failure
function OneDriveApi:createShareLink(path, token, link_type)
    link_type = link_type or "view"
    local drive_path = buildDrivePath(path)
    local url = GRAPH_BASE .. "/me/drive/" .. drive_path .. ":/createLink"
    local body = JSON.encode({ type = link_type })
    local sink = {}
    socketutil:set_timeout()
    local code, _, status = socket.skip(1, http.request{
        url     = url,
        method  = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"]  = "application/json",
            ["Content-Length"] = string.len(body),
        },
        source  = ltn12.source.string(body),
        sink    = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if code >= 200 and code <= 299 then
        local _, result = pcall(JSON.decode, table.concat(sink))
        return result
    end
    logger.warn("OneDriveApi: cannot create share link:", status or code)
end

--- Get detailed metadata for a file or folder.
-- @param path user-facing path
-- @param token access token
-- @return table|nil item metadata, or nil on failure
function OneDriveApi:getItemMetadata(path, token)
    local drive_path = buildDrivePath(path)
    local url = GRAPH_BASE .. "/me/drive/" .. drive_path
    local sink = {}
    socketutil:set_timeout()
    local code, _, status = socket.skip(1, http.request{
        url     = url,
        method  = "GET",
        headers = {
            ["Authorization"] = "Bearer " .. token,
        },
        sink    = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if code == 200 then
        local _, result = pcall(JSON.decode, table.concat(sink))
        return result
    end
    logger.warn("OneDriveApi: cannot get item metadata:", status or code)
end

--- Create a writable upload session for large files (> 4 MB).
-- @param path user-facing destination path (e.g. "/Documents/large.pdf")
-- @param token access token
-- @return table|nil { uploadUrl, expirationDateTime }, or nil on failure
function OneDriveApi:createUploadSession(path, token)
    local drive_path = buildDrivePath(path)
    local url = GRAPH_BASE .. "/me/drive/" .. drive_path .. ":/createUploadSession"
    local body = JSON.encode({ item = { ["@microsoft.graph.conflictBehavior"] = "replace" } })
    local sink = {}
    socketutil:set_timeout()
    local code, _, status = socket.skip(1, http.request{
        url     = url,
        method  = "POST",
        headers = {
            ["Authorization"] = "Bearer " .. token,
            ["Content-Type"]  = "application/json",
            ["Content-Length"] = string.len(body),
        },
        source  = ltn12.source.string(body),
        sink    = ltn12.sink.table(sink),
    })
    socketutil:reset_timeout()
    if code == 200 then
        local _, result = pcall(JSON.decode, table.concat(sink))
        return result
    end
    logger.warn("OneDriveApi: cannot create upload session:", status or code)
end

return OneDriveApi
