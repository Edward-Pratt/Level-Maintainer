-- Level Maintainer's installer and updater. It follows the stable releases on GitHub (vX.Y.Z tags) and checks
-- every file against the release's SHA256SUMS before installing anything.
--
--   installer               install the newest stable release, or update to it
--   installer --check       only say whether a newer release is out
--   installer --rollback    go back to the version installed before this one
--   installer v1.2.0-rc.1   install exactly this release (a release candidate, or an older one)
--
-- Run it from the folder Level Maintainer lives in (normally /home). Installing needs an Internet Card and a Data
-- Card (any tier, for SHA-256); both can come out afterwards. config.lua is never replaced: a newer release's copy
-- is written beside it as config.default.lua. The files a release replaces are kept in .previous for --rollback.
-- Maintainer.lua loads this file with "--module" (marker: LM_INSTALLER_MODULE) for its daily check.

local component = require("component")
local computer = require("computer")
local filesystem = require("filesystem")
local shell = require("shell")

local REPO = "Edward-Pratt/Level-Maintainer"
local LATEST = "https://api.github.com/repos/" .. REPO .. "/releases/latest"
local DOWNLOAD = "https://github.com/" .. REPO .. "/releases/download/"

-- What an install made before releases (straight from master) holds, for the first update from one.
local LEGACY = { "Maintainer.lua", "installer.lua", "src.AE2.lua", "src.Identity.lua", "src.Utility.lua" }

local M = {}

-- Versions ------------------------------------------------------------------------------------------------------

-- {major, minor, patch, rc} for vX.Y.Z or vX.Y.Z-rc.N; a stable release sorts after its candidates.
local function parse(tag)
    if type(tag) ~= "string" then return nil end
    local a, b, c, rc = tag:match("^v(%d+)%.(%d+)%.(%d+)%-rc%.(%d+)$")
    if not a then a, b, c = tag:match("^v(%d+)%.(%d+)%.(%d+)$") end
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c), rc and tonumber(rc) or math.huge }
end

function M.isStable(tag) return type(tag) == "string" and tag:match("^v%d+%.%d+%.%d+$") ~= nil end
function M.isTag(tag) return parse(tag) ~= nil end

-- True when tag is newer than installed (anything is newer than no install, or one from before releases).
function M.newer(tag, installed)
    local a, b = parse(tag), parse(installed)
    if not a then return false end
    if not b then return true end
    for i = 1, 4 do
        if a[i] ~= b[i] then return a[i] > b[i] end
    end
    return false
end

-- Files ---------------------------------------------------------------------------------------------------------

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function writeFile(path, data)
    local f, err = io.open(path, "wb")
    if not f then error("can't write " .. path .. ": " .. tostring(err), 0) end
    f:write(data)
    f:close()
end

local function move(from, to)
    if filesystem.exists(to) then error("can't move " .. from .. ": " .. to .. " is in the way", 0) end
    local ok, err = filesystem.rename(from, to)
    if not ok then error("can't move " .. from .. " to " .. to .. ": " .. tostring(err), 0) end
end

-- A release holds files, not folders, so src/X.lua is published as src.X.lua.
local function target(name)
    local src = name:match("^src%.([%w_%-]+%.lua)$")
    if src then return "src/" .. src end
    return name
end

-- The names a release may install. They come from the network, so nothing else (no "..", no "/") gets written.
local function allowed(name)
    return name == "VERSION" or name:match("^[%w_%-]+%.lua$") ~= nil or name:match("^src%.[%w_%-]+%.lua$") ~= nil
end

local function readList(path)
    local text = readFile(path)
    if not text then return nil end
    local list = {}
    for line in text:gmatch("[^\n]+") do list[#list + 1] = line end
    return list
end

local function writeList(path, list)
    writeFile(path, table.concat(list, "\n") .. "\n")
end

-- The installed version, or nil for none (or an install from before releases).
function M.installed(dir)
    local text = readFile(dir .. "/VERSION")
    return text and text:match("^%s*(%S+)") or nil
end

-- The release files in dir, as release names.
local function installedFiles(dir)
    local list = readList(dir .. "/.manifest")
    if list then return list end
    if filesystem.exists(dir .. "/Maintainer.lua") then return LEGACY end
    return {}
end

-- Network -------------------------------------------------------------------------------------------------------

local function get(url)
    if not url:match("^https://") then error("refusing a URL that isn't HTTPS: " .. url, 0) end
    if not component.isAvailable("internet") then
        error("this needs an Internet Card. Put one in and run it again; it can come out afterwards.", 0)
    end
    local internet = require("internet")
    local handle = internet.request(url, nil, { ["User-Agent"] = "Level-Maintainer-installer" })
    local deadline = computer.uptime() + 30
    while true do
        local ok, err = handle.finishConnect()
        if ok then break end
        if ok == nil then error("can't reach " .. url .. ": " .. tostring(err), 0) end
        if computer.uptime() > deadline then
            handle.close()
            error("timed out reaching " .. url, 0)
        end
        os.sleep(0.1)
    end
    local code = handle.response()
    if code ~= 200 then
        handle.close()
        if code == 403 or code == 429 then
            error("GitHub refused " .. url .. " (HTTP " .. code .. "), probably its hourly rate limit. Try later.", 0)
        end
        error("HTTP " .. tostring(code) .. " from " .. url, 0)
    end
    local parts = {}
    for chunk in handle do parts[#parts + 1] = chunk end
    return table.concat(parts)
end

-- The newest stable release's tag. GitHub's "latest" release skips pre-releases.
function M.latest()
    local ok, body = pcall(get, LATEST)
    if not ok then
        if tostring(body):find("HTTP 404", 1, true) then
            error("Level Maintainer has no stable release yet. To install a release candidate: installer vX.Y.Z-rc.N", 0)
        end
        error(body, 0)
    end
    local tag = body:match('"tag_name"%s*:%s*"([^"]*)"')
    if not tag then error("GitHub's answer names no release", 0) end
    if not M.isStable(tag) then error("the newest release, " .. tag .. ", isn't a vX.Y.Z release; not following it", 0) end
    return tag
end

local function sha256(data)
    local card = component.data
    if card.getLimit and #data > card.getLimit() then
        error("a file is larger than this Data Card can hash (" .. card.getLimit() .. " bytes)", 0)
    end
    local raw = card.sha256(data)    -- 32 raw bytes, not hex
    return (raw:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- Installing ----------------------------------------------------------------------------------------------------

-- Moves the files listed in src/.manifest into dir. The files they replace (and the release files no longer
-- shipped) go to .previous, replacing the one before. If a move fails, everything goes back where it was.
local function swapIn(dir, src)
    local incoming = readList(src .. "/.manifest") or error("nothing to install in " .. src, 0)
    local swap = dir .. "/.swap"
    filesystem.remove(swap)
    filesystem.makeDirectory(swap)
    filesystem.makeDirectory(dir .. "/src")

    local outgoing, seen = {}, {}
    for _, list in ipairs({ installedFiles(dir), incoming }) do
        for _, name in ipairs(list) do
            if not seen[name] and filesystem.exists(dir .. "/" .. target(name)) then
                outgoing[#outgoing + 1] = name
            end
            seen[name] = true
        end
    end

    local moved, placed = {}, {}
    local ok, err = pcall(function()
        for _, name in ipairs(outgoing) do
            move(dir .. "/" .. target(name), swap .. "/" .. name)
            moved[#moved + 1] = name
        end
        for _, name in ipairs(incoming) do
            move(src .. "/" .. name, dir .. "/" .. target(name))
            placed[#placed + 1] = name
        end
    end)
    if not ok then
        for _, name in ipairs(placed) do pcall(move, dir .. "/" .. target(name), src .. "/" .. name) end
        for _, name in ipairs(moved) do pcall(move, swap .. "/" .. name, dir .. "/" .. target(name)) end
        filesystem.remove(swap)
        error("couldn't put the new files in place, so the old ones are back: " .. tostring(err), 0)
    end

    writeList(swap .. "/.manifest", outgoing)
    writeList(dir .. "/.manifest", incoming)
    filesystem.remove(dir .. "/.previous")
    filesystem.remove(src)
    move(swap, dir .. "/.previous")
end

-- identity.cache is rebuilt on the next start; clearing it avoids a stale entry after the code changes.
local function clearCache(dir)
    if filesystem.exists(dir .. "/identity.cache") then filesystem.remove(dir .. "/identity.cache") end
end

function M.install(dir, tag)
    if not M.isTag(tag) then error("not a release tag: " .. tostring(tag), 0) end
    if not component.isAvailable("data") then
        error("installing needs a Data Card (any tier) to check the release's SHA256SUMS. "
            .. "Put one in and run it again; it can come out afterwards. Nothing was changed.", 0)
    end

    local work = dir .. "/.update"
    filesystem.remove(work)
    filesystem.makeDirectory(work)
    local ok, err = pcall(function()
        print("Downloading Level Maintainer " .. tag .. "...")
        local sums = get(DOWNLOAD .. tag .. "/SHA256SUMS")
        local files, names = {}, {}
        for line in sums:gmatch("[^\r\n]+") do
            local hash, name = line:match("^(%x+) [ *](.+)$")
            if not hash or #hash ~= 64 then error("SHA256SUMS has a line I can't read: " .. line, 0) end
            if allowed(name) then
                files[#files + 1] = { name = name, hash = hash:lower() }
                names[name] = true
            else
                print("Skipping " .. name .. ": not a file this installer installs.")
            end
        end
        for _, need in ipairs({ "Maintainer.lua", "installer.lua", "VERSION" }) do
            if not names[need] then error(tag .. " has no " .. need .. "; not installing it", 0) end
        end

        local manifest = {}
        for _, file in ipairs(files) do
            local data = get(DOWNLOAD .. tag .. "/" .. file.name)
            if sha256(data) ~= file.hash then
                error(file.name .. " doesn't match the release's SHA256SUMS; refusing " .. tag .. ".", 0)
            end
            writeFile(work .. "/" .. file.name, data)
            if file.name ~= "config.lua" then manifest[#manifest + 1] = file.name end
        end
        if (readFile(work .. "/VERSION") or ""):match("^%s*(%S+)") ~= tag then
            error("the release's VERSION doesn't say " .. tag .. "; not installing it", 0)
        end
        writeList(work .. "/.manifest", manifest)
    end)
    if not ok then
        filesystem.remove(work)
        error(tostring(err) .. " Nothing was changed.", 0)
    end

    -- Every file is checked. config.lua isn't swapped like the rest: it's installed only when there's none.
    local hadConfig = filesystem.exists(dir .. "/config.lua")
    local config = work .. "/config.lua"
    local newConfig = nil
    if filesystem.exists(config) then newConfig = readFile(config); filesystem.remove(config) end
    local swapped, swapErr = pcall(swapIn, dir, work)
    if not swapped then
        filesystem.remove(work)
        error(swapErr, 0)
    end
    if newConfig then
        if hadConfig then
            writeFile(dir .. "/config.default.lua", newConfig)
            print("Kept your config.lua. This release's own is config.default.lua: compare them for new settings.")
        else
            writeFile(dir .. "/config.lua", newConfig)
        end
    end
    clearCache(dir)
    print("Installed Level Maintainer " .. tag .. ".")
end

function M.rollback(dir)
    local previous = dir .. "/.previous"
    if not filesystem.exists(previous .. "/.manifest") then
        error("there's no earlier version to go back to", 0)
    end
    local version = M.installed(previous) or "the version from before releases"
    swapIn(dir, previous)
    clearCache(dir)
    print("Went back to Level Maintainer " .. version .. ". installer --rollback again returns to the newer one.")
end

-- Command -------------------------------------------------------------------------------------------------------

local function main(arg)
    local dir = shell.getWorkingDirectory()
    if arg == "--check" then
        local tag, installed = M.latest(), M.installed(dir)
        print("installed " .. (installed or "none"))
        print("available " .. tag)
        if M.newer(tag, installed) then print("Run installer to update.") end
        return
    elseif arg == "--rollback" then
        M.rollback(dir)
    elseif arg == nil then
        local tag, installed = M.latest(), M.installed(dir)
        if installed == tag then
            print("Level Maintainer is up to date: " .. tag .. ".")
            return
        elseif installed and not M.newer(tag, installed) then
            print("This runs " .. installed .. ", newer than the latest stable release " .. tag
                .. ". installer " .. tag .. " goes back to it.")
            return
        end
        M.install(dir, tag)
    elseif M.isTag(arg) then
        M.install(dir, arg)
    else
        io.stderr:write("Usage: installer [--check | --rollback | vX.Y.Z]\n")
        return
    end
    print("Rebooting...")
    computer.shutdown(true)
end

if select(1, ...) == "--module" then return M end

local ok, err = pcall(main, ...)
if not ok then
    io.stderr:write("installer: " .. tostring(err) .. "\n")
    return false
end
return true
