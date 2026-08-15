# Level Maintainer

Keeps items and fluids topped up in an AE2 network, without the lag and randomness
of the in-game Level Maintainer.

This fork targets **GTNH 2.9**, where the OpenComputers AE2 integration gained the
AE2 StackApi. That replaced the old "scan every craftable and filter it in Lua"
approach with direct lookups, so a maintained list no longer costs a full network
walk on every pass.

---

## Requirements

**Modpack** — GTNH 2.9 or newer. Specifically you need an ME interface that exposes
`getCraftable`, which arrived with the StackApi rework (OpenComputers 1.12.4x-GTNH).
The script checks this on startup and tells you if it is missing. To check yourself:

```bash
lua -e "print(require('component').me_interface.getCraftable ~= nil)"
```

**In-world setup**

- A **full-block ME Interface** (not the part) touching an **Adapter**
- A **Crafting Monitor** on each crafting CPU — without one, the CPU cannot report
  what it is working on and the script will re-request things already in progress
- Any basic OpenComputers computer: Tier 2 case, CPU, 2× Tier 1.5 RAM, HDD, screen
  and GPU, keyboard
- An **Internet Card** for the installer only. It can be removed afterwards

---

## Installation

```bash
wget raw.githubusercontent.com/Edward-Pratt/Level-Maintainer/master/installer.lua && installer
```

The computer reboots when the installer finishes. Then edit `config.lua` and run:

```bash
Maintainer
```

To start it automatically on boot, add it to `/home/.shrc`:

```bash
echo Maintainer >> /home/.shrc
```

---

## Configuration

Everything lives in `config.lua`. Entries are keyed by the label exactly as shown in
the ME terminal.

### Items

```lua
cfg["items"] = {
    ["Osmium Dust"] = {64, 64},                 -- keep 64 in stock, request 64 at a time
    ["drop of Molten SpaceTime"] = {nil, 1},    -- no threshold: request every pass
}
```

`["label"] = {threshold, batch}`

- `threshold` — keep at least this many in the network. `nil` means request on every
  pass, relying on the crafting-CPU check to avoid piling up duplicate jobs.
- `batch` — how many to request at a time.

There is also a named form, which is the only way to set a per-entry CPU:

```lua
["Osmium Dust"] = {threshold = 64, batch = 64, cpu = "MaintenanceCPU"},
```

**AE2FC fluid drops no longer need the fluid name.** Older versions of this script
took a third value (`{1000000, 1, "spacetime"}`) to rebuild the drop's NBT by hand.
The NBT tag is now read straight off the pattern and cached, so drop the third value —
it is ignored, with a note in the log.

### Fluids (2.9+)

Fluid craftables can be requested directly now, in real mB, with no fluid-drop
middleman:

```lua
cfg["fluids"] = {
    ["Molten SpaceTime"] = {1000000, 16000},   -- keep 1000 B, request 16 B at a time
}
```

`["label"] = {threshold_mb, batch_mb}`

Leave the block empty if you do not need it.

### Behaviour

| Key | Default | Meaning |
| --- | --- | --- |
| `sleep` | `10` | Seconds between passes |
| `cpu` | `nil` | Send every request to one named crafting CPU |
| `events` | `false` | Wake on network changes instead of waiting out the interval |
| `minInterval` | `2` | Floor on cycle rate when `events` is on |

Setting `cpu` is worth doing on a big base: it keeps routine top-ups off the CPUs
with all your co-processors, so a maintenance job never occupies the CPU you wanted
for a big craft.

Restart the script after editing the config.

---

## How it works, and what got faster

The old version called `getCraftables({label = ...})` **once per configured entry,
per pass**. That call walks every stack in every storage type in the network and
converts each craftable into a full Lua table — compressing NBT and looking up ore
dictionary names along the way — just to find one label. Ten maintained items meant
ten full network walks every ten seconds.

There was an item cache meant to soften this, but it used `os.time()` for its clock.
In OpenComputers `os.time()` follows the in-game clock, which runs 72× faster than
real time, so the intended 10-minute cache actually expired after about 8 real
seconds — shorter than the poll interval. It was rescanning on essentially every
pass.

What the script does now:

1. **Resolve each label once, ever.** A label is resolved to a concrete stack
   identity (`name`, `damage`, NBT `tag`, or fluid registry name) and written to
   `identity.cache` on disk. That is the only thing that still needs a network scan,
   and after the first run it does not happen again — even across reboots.
2. **Check stock with a direct lookup.** `getItemInNetwork` in its 2.9 detail-table
   form, or `getFluidInNetwork` for fluids. Both are hash lookups against the storage
   monitor rather than a scan. Steady state is exactly one cheap lookup per entry
   per pass.
   - The table form also fixes NBT matching. The three-argument form expects NBT as
     an *SNBT string*, but the tag you get back from a stack is *compressed bytes* —
     passing one to the other never matched. The table form round-trips the bytes as
     they are.
3. **Skip idle CPUs.** `getCpus()` already reports `busy` in the table it returns, so
   `finalOutput()` is only called on CPUs actually doing something.
4. **Do not block on requests.** The old loop slept in a one-second poll until each
   request finished computing, which serialised the whole list behind the slowest
   recipe. Requests are now fired and their status checked on later passes.
5. **Pin to a CPU** via `request(amount, prioritizePower, cpuName)`.

Net effect: with a warm `identity.cache`, a normal pass makes one `getCpus()` call,
one `finalOutput()` per busy CPU, and one stock lookup per entry. No network scans.

Because thresholds are now a hash lookup rather than a scan, the old warning about
thresholds being expensive no longer applies — use them freely.

### Event mode

`cfg.events = true` uses `setItemEventSubscription`, so the script wakes on
`network_item_changed` instead of waiting out `sleep`. Useful if you want tight
thresholds reacting quickly.

Two caveats before turning it on:

- On an active network this signal fires **constantly** — every insert, every craft
  output. `minInterval` keeps the loop from spinning, but the computer still has to
  chew through the event queue. Polling every few seconds is usually the calmer
  choice.
- With `insertIdsInConverters=true` (the GTNH default in `config/OpenComputers.cfg`),
  every one of those events makes the server log
  `Trying to push signal with an unsupported argument of type [Ljava.lang.String;`.
  It is harmless but it will flood a server log. See
  [GTNH issue #26028](https://github.com/GTNewHorizons/GT-New-Horizons-Modpack/issues/26028).

---

## Troubleshooting

**`no me_interface component`** — the Adapter is not touching a full-block ME
Interface. The interface *part* does not work.

**`this ME interface has no getCraftable()`** — the pack is older than 2.9, or
OpenComputers predates the StackApi rework.

**`X is not craftable`** — the label does not match a pattern. It must match the ME
terminal exactly, including capitalisation. The script retries every 60 seconds, so
if you are still building the pattern it will pick it up on its own.

**`X is craftable but not as a item`** — the label resolved to the wrong type, e.g. a
fluid label listed under `cfg.items`. Move it to the other block.

**Something is requested that should not be, or the wrong variant is matched** — the
cached identity is stale. Clear it:

```bash
Maintainer --rescan
```

**Requests never appear** — check that your crafting CPUs have Crafting Monitors.
Without them `finalOutput()` returns nothing and the duplicate-job guard cannot work.

**`ERROR: ... (3/10)` in the log** — a component call failed, usually the chunk with
the interface unloading or a cable being broken. The script logs it and carries on;
ten consecutive failures stop it, on the assumption the setup is genuinely broken
rather than briefly unavailable. Ctrl+C always stops it immediately.
