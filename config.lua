local cfg = {}

-- ITEMS -----------------------------------------------------------------------
--
-- Keyed by the label exactly as it appears in the ME terminal.
--
--   [label] = {threshold, batch}
--
-- threshold  keep at least this many in the network (nil = craft every cycle)
-- batch      how many to request at a time
--
-- The named form works too, and is the only way to pin a single entry to a CPU:
--   ["Osmium Dust"] = {threshold = 64, batch = 64, cpu = "MaintenanceCPU"}
--
-- NBT is handled automatically. AE2FC fluid drops no longer need the fluid name
-- spelled out -- the identity (including the NBT tag) is read from the pattern
-- once and cached in identity.cache.

cfg["items"] = {
    ["drop of Molten SpaceTime"] = {nil, 1},
    ["drop of Molten White Dwarf Matter"] = {nil, 1},
    -- ["Osmium Dust"] = {64, 64},
}

-- FLUIDS ----------------------------------------------------------------------
--
-- Native fluid maintenance, GTNH 2.9+ only. Amounts are real mB, so there is no
-- need to go through fluid drops.
--
--   [label] = {threshold_mb, batch_mb}

cfg["fluids"] = {
    -- ["Molten SpaceTime"] = {1000000, 16000},
}

-- BEHAVIOUR -------------------------------------------------------------------

-- Seconds between passes.
cfg["sleep"] = 10

-- Optional: send every request to one named crafting CPU, keeping routine
-- top-ups off the CPUs you reserve for big jobs. Must match the CPU name
-- exactly, or leave nil to let AE2 choose.
cfg["cpu"] = nil

-- Optional: wake as soon as the network reports a stock change instead of
-- waiting out the full interval (uses setItemEventSubscription).
--
-- Only worth enabling for tight thresholds. On a busy network this fires
-- constantly, and with insertIdsInConverters=true it spams the server log --
-- see the README before turning it on.
cfg["events"] = false

-- Floor on how often a cycle may run in event mode.
cfg["minInterval"] = 2

return cfg
