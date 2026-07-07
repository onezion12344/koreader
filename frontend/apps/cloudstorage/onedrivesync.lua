local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local OneDriveApi = require("apps/cloudstorage/onedriveapi")
local UIManager = require("ui/uimanager")
local ffiUtil = require("ffi/util")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local Notification = require("ui/widget/notification")
local _ = require("gettext")

local OneDriveSync = {}

-- OneDrive folder used for sync metadata (hidden from normal browsing)
local SYNC_ROOT_FOLDER = ".koreader-sync"

-- Resolve access token (reuse from OneDrive module if available, or standalone)
local function resolveToken(od_settings)
    if not od_settings or not od_settings.refresh_token then
        return nil
    end
    local now = os.time()
    if od_settings.access_token and od_settings.expires_at and now < od_settings.expires_at - 60 then
        return od_settings.access_token
    end
    local result = OneDriveApi:refreshAccessToken(od_settings.refresh_token, od_settings.client_id)
    if result and result.access_token then
        od_settings.access_token = result.access_token
        if result.refresh_token then
            od_settings.refresh_token = result.refresh_token
        end
        od_settings.expires_at = now + (result.expires_in or 3600)
        return od_settings.access_token
    end
end

--- Ensure the sync root folder exists on OneDrive.
local function ensureSyncRoot(token)
    OneDriveApi:createFolder("/", token, SYNC_ROOT_FOLDER)
end

--- Get the sidecar directory path for a given book file.
-- KOReader sidecar: /path/to/book.pdf has sidecar at /path/to/book.sdr/
local function getSidecarPath(book_path)
    return book_path:gsub("%.[^%.]+$", "") .. ".sdr"
end

--- List all files in a local directory (non-recursive).
local function listLocalDir(dir_path)
    local files = {}
    local ok, iter, dir_obj = pcall(lfs.dir, dir_path)
    if not ok then return files end
    for f in iter, dir_obj do
        if f ~= "." and f ~= ".." then
            local full = dir_path .. "/" .. f
            local attr = lfs.attributes(full)
            if attr and attr.mode == "file" then
                table.insert(files, { name = f, path = full, size = attr.size, mod = attr.modification })
            end
        end
    end
    return files
end

--- Compute the remote sync path for a book: .koreader-sync/bookname.sdr/
local function getRemoteSyncPath(book_path)
    local basename = ffiUtil.basename(book_path)
    local sidecar_name = basename:gsub("%.[^%.]+$", "") .. ".sdr"
    return SYNC_ROOT_FOLDER .. "/" .. sidecar_name
end

--- Upload a single sidecar file to OneDrive.
local function uploadSidecarFile(od_settings, remote_folder, local_file_path, filename)
    local token = resolveToken(od_settings)
    if not token then return false end
    local code = OneDriveApi:uploadFile(remote_folder, token, local_file_path)
    return code >= 200 and code <= 299
end

--- Download a single file from OneDrive by remote path.
local function downloadSidecarFile(od_settings, remote_path, local_path)
    local token = resolveToken(od_settings)
    if not token then return false end
    local code = OneDriveApi:downloadFileByPath(remote_path, token, local_path)
    return code == 200
end

--- Push local sidecar changes to OneDrive.
-- Compares local sidecar files to last-known state, uploads changes.
-- @param book_path full path to the book file
-- @param od_settings OneDrive settings table
-- @param callback optional function(success, message)
function OneDriveSync:pushSidecar(book_path, od_settings, callback)
    if NetworkMgr:willRerunWhenOnline(function()
        self:pushSidecar(book_path, od_settings, callback)
    end) then
        return
    end

    local sidecar_path = getSidecarPath(book_path)
    local attr = lfs.attributes(sidecar_path)
    if not attr or attr.mode ~= "directory" then
        -- No sidecar exists, nothing to push
        if callback then callback(true, "No sidecar to push") end
        return
    end

    local token = resolveToken(od_settings)
    if not token then
        if callback then callback(false, "Authentication failed") end
        return
    end

    ensureSyncRoot(token)

    local remote_path = getRemoteSyncPath(book_path)
    local local_files = listLocalDir(sidecar_path)

    -- Read last sync state
    local sync_db = self:_readSyncDB()
    local last_synced = sync_db[book_path] or {}

    local uploaded = 0
    for _, file in ipairs(local_files) do
        local last = last_synced[file.name]
        -- Upload if file is new or changed
        if not last or last.size ~= file.size or last.mod ~= file.mod then
            local ok = uploadSidecarFile(od_settings, remote_path, file.path, file.name)
            if ok then
                last_synced[file.name] = { size = file.size, mod = file.mod }
                uploaded = uploaded + 1
            end
        end
    end

    -- Save updated sync state
    sync_db[book_path] = last_synced
    self:_writeSyncDB(sync_db)

    if uploaded > 0 then
        logger.dbg("OneDriveSync: pushed", uploaded, "sidecar files for", book_path)
    end
    if callback then callback(true, "Pushed " .. uploaded .. " files") end
end

--- Pull remote sidecar from OneDrive, merging with local.
-- Downloads remote sidecar files that are newer than local.
-- @param book_path full path to the book file
-- @param od_settings OneDrive settings table
-- @param callback optional function(success, message)
function OneDriveSync:pullSidecar(book_path, od_settings, callback)
    if NetworkMgr:willRerunWhenOnline(function()
        self:pullSidecar(book_path, od_settings, callback)
    end) then
        return
    end

    local token = resolveToken(od_settings)
    if not token then
        if callback then callback(false, "Authentication failed") end
        return
    end

    local sidecar_path = getSidecarPath(book_path)
    local remote_path = getRemoteSyncPath(book_path)

    -- Ensure local sidecar directory exists
    lfs.mkdir(sidecar_path)

    -- Read last sync state
    local sync_db = self:_readSyncDB()
    local last_synced = sync_db[book_path] or {}

    -- List remote sidecar files (try to get the folder, it might not exist)
    local remote_files = OneDriveApi:showFiles(remote_path, token)
    if not remote_files or #remote_files == 0 then
        -- No remote sidecar exists yet, nothing to pull
        if callback then callback(true, "No remote sidecar") end
        return
    end

    local downloaded = 0
    for _, rfile in ipairs(remote_files) do
        local local_file = sidecar_path .. "/" .. rfile.text
        local local_attr = lfs.attributes(local_file)
        local last = last_synced[rfile.text]

        -- Download if local doesn't exist or remote is newer (size different)
        if not local_attr or (last and last.size ~= rfile.size) or not last then
            local remote_file_path = remote_path .. "/" .. rfile.text
            local ok = downloadSidecarFile(od_settings, remote_file_path, local_file)
            if ok then
                local new_attr = lfs.attributes(local_file)
                if new_attr then
                    last_synced[rfile.text] = { size = new_attr.size, mod = new_attr.modification }
                end
                downloaded = downloaded + 1
            end
        end
    end

    sync_db[book_path] = last_synced
    self:_writeSyncDB(sync_db)

    if downloaded > 0 then
        logger.dbg("OneDriveSync: pulled", downloaded, "sidecar files for", book_path)
        UIManager:show(Notification:new{
            text = _("Reading data synced from OneDrive."),
            timeout = 2,
        })
    end
    if callback then callback(true, "Pulled " .. downloaded .. " files") end
end

--- Full bidirectional sync: push local, pull remote, merge.
-- This is the main sync entry point — call on document open and close.
-- @param book_path full path to the book file
-- @param od_settings OneDrive settings table
function OneDriveSync:fullSync(book_path, od_settings)
    -- Pull first (get remote changes), then push (send local changes)
    self:pullSidecar(book_path, od_settings, function(pull_ok, _pull_msg)
        if pull_ok then
            self:pushSidecar(book_path, od_settings, function(_push_ok, _push_msg)
                -- Done, notification handled by pushSidecar
            end)
        end
    end)
end

--- Read the sync tracking database.
function OneDriveSync:_readSyncDB()
    local db_path = DataStorage:getSettingsDir() .. "/onedrivesync.lua"
    local settings = LuaSettings:open(db_path)
    return settings:readSetting("sync_state") or {}
end

--- Write the sync tracking database.
function OneDriveSync:_writeSyncDB(state)
    local db_path = DataStorage:getSettingsDir() .. "/onedrivesync.lua"
    local settings = LuaSettings:open(db_path)
    settings:saveSetting("sync_state", state)
    settings:flush()
end

return OneDriveSync
