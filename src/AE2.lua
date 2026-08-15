local component = require("component")
local Identity = require("src.Identity")

local ME = component.me_interface

local AE2 = {}

-- GTNH 2.9 (OpenComputers 1.12.4x-GTNH + the AE2 StackApi rework) added direct
-- lookups that replace the old "scan every craftable and filter in Lua"
-- approach. Probe for them rather than trusting a version number.
AE2.caps = {
    getCraftable = ME.getCraftable ~= nil,
    fluids = ME.getFluidInNetwork ~= nil,
    itemEvents = ME.setItemEventSubscription ~= nil
}

-- Craftable handles are only needed to issue a request, and the recipe for a
-- given stack identity does not change while the script runs, so these are
-- cached for the lifetime of the process.
local craftables = {}

-- Current stock for a stack identity, in items or mB. Returns 0 when the
-- network holds none.
--
-- Both of these are hash lookups against the storage monitor. The item form
-- takes the detail-table variant so the NBT tag round-trips as raw bytes --
-- the string variant expects SNBT and cannot represent a compressed tag.
function AE2.getStock(id)
    if id.type == "fluid" then
        local stack = ME.getFluidInNetwork(id.name)
        if stack == nil then return 0 end
        return stack.amount or stack.size or 0
    end

    local stack = ME.getItemInNetwork({
        ["name"] = id.name,
        ["damage"] = id.damage or 0,
        ["tag"] = id.tag
    })
    if stack == nil then return 0 end
    return stack.size or 0
end

-- Fetches (and caches) the craftable handle for a stack identity.
function AE2.getCraftable(id)
    local key = Identity.key(id)

    local craftable = craftables[key]
    if craftable ~= nil then
        if craftable == false then return nil end
        return craftable
    end

    local detail = { ["name"] = id.name }
    if id.type == "item" then
        detail.damage = id.damage or 0
        detail.tag = id.tag
    end

    craftable = ME.getCraftable(detail, id.type)
    craftables[key] = craftable or false
    return craftable
end

-- Issues a crafting request and returns the job handle without waiting for the
-- CPU to finish planning. The caller polls it later so one slow recipe cannot
-- stall the rest of the list.
--
-- `cpuName` optionally pins the job to a named crafting CPU, which keeps
-- routine top-ups off the CPUs reserved for big jobs.
function AE2.request(id, amount, cpuName)
    local craftable = AE2.getCraftable(id)
    if craftable == nil then
        return nil, (id.label or id.name) .. " has no crafting pattern"
    end

    local job, reason
    if cpuName ~= nil and cpuName ~= "" then
        job, reason = craftable.request(amount, true, cpuName)
    else
        job, reason = craftable.request(amount)
    end

    if job == nil then
        return nil, "could not request " .. (id.label or id.name) .. ": " .. tostring(reason)
    end

    return job
end

-- Drops the cached craftable handle, forcing a fresh lookup next cycle.
function AE2.forget(id)
    craftables[Identity.key(id)] = nil
end

-- Set of stack keys that a crafting CPU is currently working towards.
--
-- getCpus() already reports `busy` in the returned table, so idle CPUs are
-- skipped without a further component call into finalOutput().
function AE2.busyOutputs()
    local outputs = {}

    for _, entry in pairs(ME.getCpus()) do
        if entry.busy then
            local output = entry.cpu.finalOutput()
            if output ~= nil and output.name ~= nil then
                outputs[Identity.key(output)] = true
            end
        end
    end

    return outputs
end

function AE2.setItemEvents(enabled)
    if AE2.caps.itemEvents then
        ME.setItemEventSubscription(enabled)
    end
end

return AE2
