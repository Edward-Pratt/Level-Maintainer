-- Runs installer.lua against fake releases, with OpenComputers' component, computer, filesystem, internet and shell
-- stubbed over a temporary folder. Run from the repository's root: lua test/installer.lua
-- It needs a POSIX shell with sha256sum. It can't stand in for a test in game: see the README.

local root = arg[0]:match("^(.*)/test/[^/]*$") or "."
local function sh(cmd) return os.execute(cmd) == true end
local function q(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local tmp = os.tmpname()
os.remove(tmp)
assert(sh("mkdir -p " .. q(tmp)))
local releases, home = tmp .. "/releases", tmp .. "/home"

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end
local function write(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end
local function sha256hex(path)
    local p = io.popen("sha256sum " .. q(path))
    local out = p:read("*a")
    p:close()
    return out:match("^(%x+)")
end

-- OpenComputers ---------------------------------------------------------------------------------------------------

local hw = { internet = true, data = true }
local state = { rebooted = false, urls = {}, latest = nil, uptime = 0 }

local filesystem = {
    exists = function(p) return sh("test -e " .. q(p)) end,
    isDirectory = function(p) return sh("test -d " .. q(p)) end,
    makeDirectory = function(p) return sh("mkdir -p " .. q(p)) end,
    remove = function(p) return sh("rm -rf " .. q(p)) end,
    -- Like OC's: it fails when the destination exists.
    rename = function(a, b)
        if sh("test -e " .. q(b)) then return nil, "file exists" end
        if state.failRename and a:find(state.failRename, 1, true) then return nil, "disk full" end
        return os.rename(a, b)
    end,
}

local component = {
    isAvailable = function(name) return hw[name] == true end,
    data = {
        getLimit = function() return 1048576 end,
        -- Raw bytes, as the Data Card returns them, not hex.
        sha256 = function(data)
            local f = tmp .. "/hash-input"
            write(f, data)
            return (sha256hex(f):gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end))
        end,
    },
}

local API = "https://api.github.com/repos/Edward-Pratt/Level-Maintainer/releases/latest"
local DOWNLOAD = "https://github.com/Edward-Pratt/Level-Maintainer/releases/download/"

local internet = {
    request = function(url)
        state.urls[#state.urls + 1] = url
        assert(url:match("^https://"), "the installer asked for a non-HTTPS URL: " .. url)
        local code, body = 404, "Not Found"
        if url == API then
            if state.latest then code, body = 200, '{"url": "x", "tag_name" : "' .. state.latest .. '", "draft": false}' end
        elseif url:sub(1, #DOWNLOAD) == DOWNLOAD then
            local data = read(releases .. "/" .. url:sub(#DOWNLOAD + 1))
            if data then code, body = 200, data end
        end
        local sent = false
        return setmetatable({
            finishConnect = function() return true end,
            response = function() return code, "", {} end,
            close = function() end,
        }, {
            __call = function()
                if sent then return nil end
                sent = true
                return body
            end,
        })
    end,
}

package.loaded.component = component
package.loaded.filesystem = filesystem
package.loaded.internet = internet
package.loaded.computer = {
    uptime = function() state.uptime = state.uptime + 1; return state.uptime end,
    shutdown = function(reboot) state.rebooted = reboot end,
}
package.loaded.shell = { getWorkingDirectory = function() return home end }
os.sleep = function() end

-- Fake releases, as the release workflow builds them -----------------------------------------------------------------

local function release(tag, change)
    local dir = releases .. "/" .. tag
    assert(sh("mkdir -p " .. q(dir)))
    local files = {
        ["Maintainer.lua"] = read(root .. "/Maintainer.lua") .. "\n-- release " .. tag .. "\n",
        ["config.lua"] = read(root .. "/config.lua") .. "\n-- config of " .. tag .. "\n",
        ["installer.lua"] = read(root .. "/installer.lua"),
        ["VERSION"] = tag .. "\n",
    }
    for _, name in ipairs({ "AE2", "Identity", "Utility" }) do
        files["src." .. name .. ".lua"] = read(root .. "/src/" .. name .. ".lua") .. "\n-- release " .. tag .. "\n"
    end
    if change then change(files) end
    local sums = {}
    for name, data in pairs(files) do write(dir .. "/" .. name, data) end
    local names = {}
    for name in pairs(files) do names[#names + 1] = name end
    table.sort(names) -- as sha256sum lists them, so src.Utility.lua comes last
    for _, name in ipairs(names) do sums[#sums + 1] = sha256hex(dir .. "/" .. name) .. "  " .. name end
    write(dir .. "/SHA256SUMS", table.concat(sums, "\n") .. "\n")
    return dir
end

-- Running the installer ----------------------------------------------------------------------------------------------

local output
local function run(script, ...)
    state.rebooted, state.urls, output = false, {}, {}
    local realPrint, realStderr = print, io.stderr
    print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
        output[#output + 1] = table.concat(parts, "\t")
    end
    io.stderr = { write = function(_, s) output[#output + 1] = s end }
    local chunk = assert(loadfile(script))
    local ok, result = pcall(chunk, ...)
    print, io.stderr = realPrint, realStderr
    assert(ok, result)
    return result, table.concat(output, "\n")
end
-- The first install runs the installer from the repo (as the README's wget gets it); later ones, the installed one.
local function installer(...) return run(home .. "/installer.lua", ...) end

local failures, passed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print("ok    " .. name)
    else
        failures = failures + 1
        print("FAIL  " .. name .. (detail and ("\n      " .. tostring(detail):gsub("\n", "\n      ")) or ""))
    end
end
local function has(text, pattern) return text:find(pattern, 1, true) ~= nil end

-- Every file in home, for checking that a refused update changed nothing.
local function snapshot()
    local p = io.popen("cd " .. q(home) .. " && find . -type f | sort")
    local files = {}
    for path in p:lines() do files[#files + 1] = path .. "=" .. sha256hex(home .. "/" .. path) end
    p:close()
    return table.concat(files, "\n")
end
local function version() return (read(home .. "/VERSION") or ""):match("%S+") end

-- The tests ----------------------------------------------------------------------------------------------------------

assert(sh("mkdir -p " .. q(home)))
release("v1.0.0")
release("v1.1.0")

state.latest = nil
local ok, out = run(root .. "/installer.lua")
check("with no stable release yet, it says how to install a candidate", not ok and has(out, "no stable release yet"), out)

state.latest = "v1.0.0"
ok, out = run(root .. "/installer.lua")
check("a fresh install succeeds", ok, out)
check("it installs the release's version", version() == "v1.0.0")
check("src files go back into src/", has(read(home .. "/src/AE2.lua") or "", "-- release v1.0.0"))
check("it installs config.lua when there's none", has(read(home .. "/config.lua") or "", "config of v1.0.0"))
check("no config.default.lua on a fresh install", not filesystem.exists(home .. "/config.default.lua"))
check("the installer installs itself", read(home .. "/installer.lua") == read(root .. "/installer.lua"))
check("it reboots afterwards", state.rebooted)
check("no staging folder is left behind", not filesystem.exists(home .. "/.update") and not filesystem.exists(home .. "/.swap"))
check("every request was HTTPS", (function()
    for _, u in ipairs(state.urls) do if not u:match("^https://") then return false end end
    return true
end)())

local before = snapshot()
ok, out = installer("--check")
check("--check when up to date names both versions", has(out, "installed v1.0.0") and has(out, "available v1.0.0"), out)
check("--check doesn't offer an update when there's none", not has(out, "Run installer to update"), out)
ok, out = installer()
check("running it again says it's up to date", has(out, "up to date: v1.0.0") and not state.rebooted, out)
check("and changes nothing", snapshot() == before)

-- A newer release, with the user's own config and a warm identity cache.
write(home .. "/config.lua", "-- my own config\nreturn {}\n")
write(home .. "/identity.cache", "cached")
state.latest = "v1.1.0"
before = snapshot()
ok, out = installer("--check")
check("--check reports a newer release", has(out, "available v1.1.0") and has(out, "Run installer to update"), out)
check("--check installs nothing and doesn't reboot", snapshot() == before and not state.rebooted)
ok, out = installer()
check("the newer release installs", ok and version() == "v1.1.0", out)
check("its files are in place", has(read(home .. "/Maintainer.lua"), "-- release v1.1.0"))
check("the user's config.lua is kept", read(home .. "/config.lua") == "-- my own config\nreturn {}\n")
check("the release's config is written beside it", has(read(home .. "/config.default.lua") or "", "config of v1.1.0"))
check("and it says so", has(out, "config.default.lua"), out)
check("identity.cache is cleared", not filesystem.exists(home .. "/identity.cache"))
check("the previous version is kept", (read(home .. "/.previous/VERSION") or ""):match("%S+") == "v1.0.0")
check("it reboots", state.rebooted)

ok, out = installer("--rollback")
check("--rollback goes back to the previous version", ok and version() == "v1.0.0", out)
check("with its files", has(read(home .. "/src/Identity.lua"), "-- release v1.0.0"))
check("and leaves config.lua alone", read(home .. "/config.lua") == "-- my own config\nreturn {}\n")
check("the newer one becomes the one to go back to", (read(home .. "/.previous/VERSION") or ""):match("%S+") == "v1.1.0")
check("it reboots after a rollback", state.rebooted)
ok, out = installer("--rollback")
check("rolling back again returns to the newer one", version() == "v1.1.0", out)

-- A release whose file was changed after its checksums were written.
local dir = release("v1.2.0")
write(dir .. "/src.AE2.lua", "error('tampered')\n")
state.latest = "v1.2.0"
before = snapshot()
ok, out = installer()
check("a tampered file is refused", has(out, "src.AE2.lua doesn't match") and has(out, "Nothing was changed"), out)
check("the installed files are untouched", snapshot() == before)
check("it doesn't reboot", not state.rebooted)

-- A release missing a file its SHA256SUMS lists.
dir = release("v1.2.1")
os.remove(dir .. "/src.Utility.lua")
state.latest = "v1.2.1"
before = snapshot()
ok, out = installer()
check("a missing file is refused, with the old files kept", has(out, "HTTP 404") and snapshot() == before, out)

-- A move that fails partway through the swap.
release("v1.2.2")
state.latest = "v1.2.2"
state.failRename = "/.update/src.Utility.lua" -- the last, after the rest are in place
before = snapshot()
ok, out = installer()
state.failRename = nil
check("a swap that fails partway puts the old files back", has(out, "old ones are back") and snapshot() == before, out)

-- A release that lists a name outside the install folder.
release("v1.3.0", function(files) files["../escape.lua"] = "error('escaped')\n" end)
state.latest = "v1.3.0"
ok, out = installer()
check("a file name that would leave the folder is skipped", version() == "v1.3.0" and has(out, "Skipping ../escape.lua")
    and not filesystem.exists(tmp .. "/escape.lua"), out)

-- No Data Card.
release("v1.4.0")
state.latest = "v1.4.0"
hw.data = false
before = snapshot()
ok, out = installer()
check("without a Data Card it refuses to install", has(out, "needs a Data Card") and snapshot() == before, out)
check("and downloads nothing but the check", #state.urls == 1 and state.urls[1] == API, table.concat(state.urls, " "))
ok, out = installer("--check")
check("--check still works without a Data Card", has(out, "available v1.4.0"), out)
ok, out = installer("--rollback")
check("so does --rollback, from files already checked", version() == "v1.1.0", version())
installer("--rollback")
hw.data = true

-- No Internet Card.
hw.internet = false
ok, out = installer()
check("without an Internet Card it says one is needed", has(out, "needs an Internet Card"), out)
hw.internet = true

-- Pre-releases.
release("v1.5.0-rc.1")
state.latest = "v1.5.0-rc.1"
ok, out = installer()
check("a latest release that isn't vX.Y.Z is not followed", has(out, "isn't a vX.Y.Z release"), out)
ok, out = installer("v1.5.0-rc.1")
check("a release candidate installs when named", version() == "v1.5.0-rc.1", out)
state.latest = "v1.4.0"
ok, out = installer()
check("a newer candidate isn't downgraded to the latest stable", version() == "v1.5.0-rc.1" and has(out, "newer than"), out)
ok, out = installer("--check")
check("--check doesn't offer an older stable release", not has(out, "Run installer to update"), out)
ok, out = installer("../v1")
check("anything else as an argument is refused", has(out, "Usage") and version() == "v1.5.0-rc.1", out)

-- An install from before releases (straight from master), updated to a release.
assert(sh("rm -rf " .. q(home) .. " && mkdir -p " .. q(home .. "/src")))
for _, f in ipairs({ "Maintainer.lua", "installer.lua", "src/AE2.lua", "src/Identity.lua", "src/Utility.lua" }) do
    write(home .. "/" .. f, "-- legacy " .. f .. "\n")
end
write(home .. "/config.lua", "-- legacy config\n")
state.latest = "v1.4.0"
ok, out = run(root .. "/installer.lua")
check("an install from master updates to a release", version() == "v1.4.0", out)
check("keeping its config", read(home .. "/config.lua") == "-- legacy config\n")
check("and keeping its files for --rollback", read(home .. "/.previous/src.AE2.lua") == "-- legacy src/AE2.lua\n")

-- What Maintainer.lua's daily check uses.
local M = run(home .. "/installer.lua", "--module")
check("as a module, it reports the latest release", type(M) == "table" and M.latest() == "v1.4.0")
check("and compares versions", M.newer("v1.4.1", "v1.4.0") and not M.newer("v1.4.0", "v1.4.0")
    and M.newer("v1.0.0", nil) and M.newer("v2.0.0", "v2.0.0-rc.3") and not M.newer("v2.0.0-rc.3", "v2.0.0")
    and M.newer("v1.10.0", "v1.9.9"))

sh("rm -rf " .. q(tmp))
print(("%d passed, %d failed"):format(passed, failures))
os.exit(failures == 0 and 0 or 1)
