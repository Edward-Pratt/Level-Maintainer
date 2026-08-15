local component = require("component")
local computer = require("computer")
local event = require("event")
local cfg = require("config")
local util = require("src.Utility")

local args = { ... }

-- ----------------------------------------------------------------------------
-- Capability check
-- ----------------------------------------------------------------------------

-- src.AE2 and src.Identity bind the component when they load, and indexing a
-- missing primary component raises rather than returning nil -- so this check
-- has to happen before they are required.
if not component.isAvailable("me_interface") then
    util.log("ERROR: no me_interface component. Connect a full-block ME Interface to an Adapter.")
    return
end

local ae2 = require("src.AE2")
local Identity = require("src.Identity")

if not ae2.caps.getCraftable then
    util.log("ERROR: this ME interface has no getCraftable(). GTNH 2.9 or newer is required.")
    return
end

-- ----------------------------------------------------------------------------
-- Config
-- ----------------------------------------------------------------------------

local interval = cfg.sleep or 10
local minInterval = cfg.minInterval or 2
local useEvents = cfg.events == true and ae2.caps.itemEvents

if cfg.events == true and not ae2.caps.itemEvents then
    util.log("WARNING: cfg.events is set but this interface has no setItemEventSubscription. Polling instead.")
end

-- Accepts either the positional form {threshold, batch} or the named form
-- {threshold = ..., batch = ...}.
local function normalise(label, entry, kind)
    return {
        label = label,
        kind = kind,
        threshold = entry.threshold or entry[1],
        batch = entry.batch or entry[2] or 1,
        cpu = entry.cpu,
        legacyFluid = entry[3]
    }
end

local pending = {}    -- key -> {entry = ..., job = userdata}
local entries = {}
local unresolved = {}

local function collect(source, kind)
    for label, entry in pairs(source or {}) do
        local item = normalise(label, entry, kind)
        if item.legacyFluid ~= nil and kind == "item" then
            util.log("NOTE: '" .. label .. "' has a legacy fluid name; NBT is now auto-detected, ignoring it.")
        end
        unresolved[#unresolved + 1] = item
    end
end

collect(cfg.items, "item")

if cfg.fluids ~= nil and next(cfg.fluids) ~= nil then
    if ae2.caps.fluids then
        collect(cfg.fluids, "fluid")
    else
        util.log("WARNING: cfg.fluids is set but this interface has no getFluidInNetwork. Skipping fluids.")
    end
end

if #unresolved == 0 then
    util.log("Nothing to maintain -- cfg.items and cfg.fluids are both empty.")
    return
end

if args[1] == "--rescan" then
    util.log("Clearing the identity cache.")
    Identity.clear()
end

-- ----------------------------------------------------------------------------
-- Label resolution
-- ----------------------------------------------------------------------------

-- Resolves whatever is still outstanding. Anything that fails stays in the
-- queue and is retried on a slow timer, so entries whose pattern does not exist
-- yet start working on their own once it does -- without scanning the network
-- every cycle or repeating the same warning.
local RESOLVE_RETRY = 60
local nextResolve = 0

local function resolvePending(now)
    if #unresolved == 0 or now < nextResolve then return end
    nextResolve = now + RESOLVE_RETRY

    local stillUnresolved = {}

    for _, item in ipairs(unresolved) do
        local id, reason = Identity.resolve(item.label, item.kind, true)
        if id ~= nil then
            item.id = id
            item.key = Identity.key(id)
            entries[#entries + 1] = item
            util.log("Maintaining " .. item.label
                .. (item.threshold and (" at " .. item.threshold) or " (no threshold)")
                .. ", batch " .. item.batch)
        else
            if item.warned ~= reason then
                util.log("WARNING: " .. reason .. " (retrying every " .. RESOLVE_RETRY .. "s)")
                item.warned = reason
            end
            stillUnresolved[#stillUnresolved + 1] = item
        end
    end

    unresolved = stillUnresolved
end

-- ----------------------------------------------------------------------------
-- Crafting
-- ----------------------------------------------------------------------------

-- Checks in-flight jobs without blocking. The old version slept in a loop
-- until each request finished computing, which serialised the whole list.
local function pollJobs()
    for key, job in pairs(pending) do
        if not job.handle.isComputing() then
            local failed, reason = job.handle.hasFailed()
            if failed then
                util.log("FAILED: " .. job.entry.label .. " x " .. job.entry.batch
                    .. (reason and (" (" .. tostring(reason) .. ")") or ""))
            else
                util.log("Requested " .. job.entry.label .. " x " .. job.entry.batch)
            end
            pending[key] = nil
        end
    end
end

local function maintain(entry, busy)
    if pending[entry.key] ~= nil then return end
    if busy[entry.key] then return end

    if entry.threshold ~= nil then
        local stock = ae2.getStock(entry.id)
        if stock >= entry.threshold then return end
    end

    local handle, reason = ae2.request(entry.id, entry.batch, entry.cpu or cfg.cpu)
    if handle == nil then
        -- Only report a given failure once, otherwise a pattern that has been
        -- removed warns on every pass, forever.
        if entry.warned ~= reason then
            util.log("WARNING: " .. reason)
            entry.warned = reason
        end
        -- The pattern may have been removed or changed; re-resolve it.
        ae2.forget(entry.id)
        return
    end

    entry.warned = nil
    pending[entry.key] = { entry = entry, handle = handle }
end

-- ----------------------------------------------------------------------------
-- Main loop
-- ----------------------------------------------------------------------------

-- In event mode the loop wakes as soon as the network reports a stock change,
-- but never runs more often than minInterval.
local function waitForNext(lastCycle)
    if not useEvents then
        os.sleep(interval)
        return
    end

    local deadline = computer.uptime() + interval
    while true do
        local remaining = deadline - computer.uptime()
        if remaining <= 0 then return end

        if event.pull(remaining, "network_item_changed") == nil then return end
        if computer.uptime() - lastCycle >= minInterval then return end
    end
end

local function cycle(now)
    resolvePending(now)
    pollJobs()

    local busy = ae2.busyOutputs()
    for _, entry in ipairs(entries) do
        maintain(entry, busy)
    end
end

-- A chunk unloading or a cable being broken makes component calls throw. That
-- should not permanently kill a script meant to run unattended, so transient
-- errors are logged and retried -- but a genuinely broken setup still stops
-- rather than looping on the same error forever.
local MAX_FAILURES = 10

local function run()
    if useEvents then
        util.log("Event mode enabled (network_item_changed).")
        ae2.setItemEvents(true)
    end

    local failures = 0

    while true do
        local lastCycle = computer.uptime()

        local ok, err = pcall(cycle, lastCycle)
        if ok then
            failures = 0
        else
            -- Ctrl+C must still stop the program.
            if tostring(err):find("interrupted", 1, true) then error(err, 0) end

            failures = failures + 1
            util.log("ERROR: " .. tostring(err) .. " (" .. failures .. "/" .. MAX_FAILURES .. ")")
            if failures >= MAX_FAILURES then
                error("giving up after " .. MAX_FAILURES .. " consecutive errors", 0)
            end
        end

        waitForNext(lastCycle)
    end
end

util.log("Level Maintainer starting (" .. (useEvents and "event" or "poll") .. " mode, "
    .. interval .. "s interval).")

local ok, err = pcall(run)

ae2.setItemEvents(false)

if not ok then
    util.log("Stopped: " .. tostring(err))
end
