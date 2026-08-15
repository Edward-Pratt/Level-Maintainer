local util = {}

function util.dump(o, depth)
    if depth == nil then depth = 0 end

    if depth > 10 then return "..." end

    if type(o) == 'table' then
        local s = '{ '
        for k, v in pairs(o) do
            local key = type(k) == 'number' and k or '"' .. tostring(k) .. '"'
            s = s .. '[' .. key .. '] = ' .. util.dump(v, depth + 1) .. ',\n'
        end
        return s .. '} '
    else
        return tostring(o)
    end
end

function util.log(message)
    -- os.date() reads the in-game clock in OpenComputers, not wall time.
    print("[" .. os.date("%H:%M:%S") .. "] " .. tostring(message))
end

-- NBT tags arrive from the ME interface as raw bytes in a Lua string. Hex is
-- the safe way to round-trip them through the on-disk identity cache.
function util.toHex(bytes)
    if bytes == nil then return nil end
    return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

function util.fromHex(hex)
    if hex == nil then return nil end
    return (hex:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
end

-- Renders a value as a Lua literal so the identity cache can be written as
-- loadable source.
function util.serialise(value, indent)
    indent = indent or ""

    if type(value) == "table" then
        local parts = {}
        for k, v in pairs(value) do
            local key = type(k) == "string" and string.format("[%q]", k) or "[" .. tostring(k) .. "]"
            parts[#parts + 1] = indent .. "    " .. key .. " = " .. util.serialise(v, indent .. "    ")
        end
        if #parts == 0 then return "{}" end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    elseif type(value) == "string" then
        return string.format("%q", value)
    else
        return tostring(value)
    end
end

return util
