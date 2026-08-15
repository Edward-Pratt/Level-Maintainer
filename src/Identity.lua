local component = require("component")
local util = require("src.Utility")

local ME = component.me_interface

-- Turns a human-readable craftable label into a concrete AE2 stack identity
-- ({type, name, damage, tag}) that the GTNH 2.9 lookups can address directly.
--
-- Resolving a label is the only operation that still needs getCraftables(),
-- which walks every stack in the network. So we do it once per label and then
-- persist the answer to disk -- after the first run the maintainer never scans
-- the network again.
local Identity = {}

local CACHE_FILE = "identity.cache"

local cache = nil    -- label -> identity table, or false for "not craftable"
local dirty = false

local function stackOf(craftable)
    -- getItemStack was renamed to getStack in the 2.9 StackApi rework.
    local get = craftable.getStack or craftable.getItemStack
    if get == nil then return nil end
    return get(craftable)
end

-- Item stacks carry `damage`; fluid stacks carry `amount` and no damage.
local function identityOf(stack)
    if stack == nil or stack.name == nil then return nil end

    if stack.damage ~= nil then
        return {
            type = "item",
            name = stack.name,
            -- Normalised so the key is stable however the number survives the
            -- trip through Lua and the on-disk cache.
            damage = math.floor(stack.damage),
            tag = stack.tag,
            label = stack.label
        }
    end

    return {
        type = "fluid",
        name = stack.name,
        label = stack.label
    }
end

-- Stable key for an identity or for any stack table returned by the interface.
function Identity.key(value)
    local kind = value.type
    if kind == nil then
        kind = value.damage ~= nil and "item" or "fluid"
    end

    if kind == "fluid" then
        return "fluid\0" .. tostring(value.name)
    end

    return "item\0" .. tostring(value.name) .. "\0" .. math.floor(value.damage or 0)
        .. "\0" .. (value.tag or "")
end

local compile = load or loadstring

local function loadCache()
    if cache ~= nil then return end
    cache = {}

    local file = io.open(CACHE_FILE, "r")
    if file == nil then return end

    local contents = file:read("*a")
    file:close()

    local chunk = compile(contents, CACHE_FILE, "t", {})
    if chunk == nil then return end

    local ok, stored = pcall(chunk)
    if not ok or type(stored) ~= "table" then return end

    for key, entry in pairs(stored) do
        if type(entry) == "table" then
            entry.tag = util.fromHex(entry.tag)
            cache[key] = entry
        end
    end
end

local function save()
    if not dirty then return end

    -- Only successful resolutions are persisted. A negative result is kept in
    -- RAM for this run only, so fixing a typo (or building the pattern) is
    -- picked up on the next restart without clearing the cache by hand.
    local out = {}
    for key, entry in pairs(cache) do
        if entry ~= false then
            out[key] = {
                type = entry.type,
                name = entry.name,
                damage = entry.damage,
                tag = util.toHex(entry.tag),
                label = entry.label
            }
        end
    end

    local file = io.open(CACHE_FILE, "w")
    if file == nil then return end

    file:write("return " .. util.serialise(out) .. "\n")
    file:close()
    dirty = false
end

-- Resolves `label` to a stack identity of the requested type ("item"/"fluid").
-- Returns nil plus a reason when the label is not a known recipe.
--
-- `force` re-runs the network scan even if the label previously missed, which
-- is how the maintainer picks up patterns that are added while it runs.
function Identity.resolve(label, wantType, force)
    loadCache()

    -- Keyed by type as well as label: the same display name can legitimately
    -- exist as both an item and a fluid, and they are different identities.
    local entryKey = wantType .. ":" .. label

    local cached = cache[entryKey]
    if cached ~= nil then
        if cached ~= false then return cached end
        if not force then return nil, label .. " is not craftable" end
    end

    local craftables = ME.getCraftables({ ["label"] = label })
    for i = 1, #craftables do
        local id = identityOf(stackOf(craftables[i]))
        if id ~= nil and id.type == wantType then
            cache[entryKey] = id
            dirty = true
            save()
            return id
        end
    end

    -- Remember the miss for this run so a typo does not trigger a full network
    -- scan every cycle. Not written to disk -- see save().
    cache[entryKey] = false

    if #craftables > 0 then
        return nil, label .. " is craftable but not as a " .. wantType
    end
    return nil, label .. " is not craftable"
end

function Identity.clear()
    cache = {}
    dirty = true
    save()
end

return Identity
