# Mooncaller

**Version:** 0.1  
**Author:** Rel  
**Client:** Turtle WoW 1.12 / SuperWoW

Druid HoT healing addon with Banzai-1.0 aggro integration, pressure-based rank selection, AoE blanket mode, and healing power scanning. Designed for raid healing with an emphasis on HoT coverage efficiency and mana conservation.

---

## Features

- **Pressure scoring** — combines HP deficit, live aggro, aggro history, and existing HoT coverage into a per-unit score driving spell and rank selection
- **Deficit-based Rejuv rank selection** — picks the lowest rank whose effective heal (including +healing contribution) covers the target's deficit. Tanks get an inflated deficit to anticipate incoming damage
- **Pressure-based Regrowth rank selection** — rank selected continuously by pressure score rather than static HP% bands
- **HoT clip protection** — `CastRegrowthSafe` prevents overwriting higher-rank Regrowth HoTs with weaker ones, preserving ticks while still landing a direct heal
- **AoE blanket mode** — when many players are uncovered, switches to Rejuv firehose over single-target Regrowth. Configurable threshold
- **Regrowth non-tank floor** — Regrowth is reserved for tanks and high-pressure non-tanks; other players receive Rejuv only unless they genuinely need it
- **Reactive Rejuv** — max rank Rejuv pre-emptively flagged on Banzai aggro pickup, delivered on next keypress
- **Own healing power scanner** — tooltip-scans all 19 equipment slots, weapon oils, and active buffs. Correctly handles active vs inactive set bonuses via pattern matching
- **Talent awareness** — Improved Rejuvenation, Gift of Nature, and Moonglow modifiers applied to rank selection and mana cost calculations
- **Clearcasting detection** — Omen of Clarity proc forces max rank Rejuv at no mana cost
- **Banzai-1.0 aggro integration** — tracks tanking in real time with aggroCount reset each combat
- **Follow-by-unitid** — resolves follow target to a party/raid unitid via GUID matching, bypassing Turtle WoW fuzzy name matching
- **Heal decision logging** — structured per-cast log exportable via SuperWoW `ExportFile`
- **Two GUI windows** — `/mcdr` for per-fight tuning, `/mcsettings` for set-once thresholds

---

## Requirements

| Dependency | Notes |
|---|---|
| **SuperWoW** | Required for `UnitPosition` (range checks) and `ExportFile` (log export) |
| **AceLibrary** | Bundled in `libs\` |
| **AceEvent-2.0** | Bundled in `libs\` |
| **RosterLib-2.0** | Bundled in `libs\` |
| **Banzai-1.0** | Bundled in `libs\` — aggro features disabled gracefully if missing |

---

## Installation

1. Copy the `Mooncaller` folder into your `Interface\AddOns\` directory:

```
Interface/
  AddOns/
    Mooncaller/
      libs/
        AceLibrary/
        AceEvent-2.0/
        RosterLib-2.0/
        Banzai-1.0/
      Mooncaller.lua
      Mooncaller.toc
```

2. Enable the addon at the character select screen and log in.

---

## Slash Commands

| Command | Description |
|---|---|
| `/mcheal` | Cast heals based on current decision logic |
| `/mcbuff` | Cast Mark of the Wild on those missing it |
| `/mctree` | Toggle auto Tree of Life Form |
| `/mcfollow` | Toggle follow on/off |
| `/mcl` | Set follow target to current target (saves unitid) |
| `/mcdr` | Healing style GUI (Regrowth floor, AoE blanket threshold) |
| `/mcsettings` | Threshold config GUI (Rejuv, Swiftmend, Trickle, MoTW, Critical) |
| `/mcstatus` | Show healing power breakdown and Rejuv effective heals per rank |
| `/mclog` | Toggle heal decision logging on/off |
| `/mcexport` | Write log buffer to `MooncallerLog.txt` |
| `/mclogclear` | Clear log buffer without writing |
| `/mclogstat` | Show log buffer status |
| `/mcrange [unit]` | Check spell ranges on unit (default: target) |
| `/mccheckbuffs` | Show player buffs and talent modifiers |
| `/mcbanzai` | Diagnose Banzai-1.0 integration |
| `/mcaggro` | Show current aggro scores |
| `/mcpressure` | Show pressure scores for all members |
| `/mcdebug` | Toggle debug output |
| `/mc` or `/mooncaller` | Show command help |

---

## Healing Logic

### Decision Priority (per `/mcheal` press)

**When nobody is below `CRITICAL_THRESHOLD` (70% HP):**

1. **Trickle pass** — cheap low-rank Rejuv (up to `TRICKLE_MAX_RANK`) on anyone below `TRICKLE_THRESHOLD` (98%) without a Rejuv. Requires mana ≥ `TRICKLE_MANA_FLOOR`. Tanks bypass the rank cap.
2. **Firehose pass** — full rank Rejuv on anyone below `REJUV_THRESHOLD` (90%) without a Rejuv.

**When anyone is below `CRITICAL_THRESHOLD` (70% HP):**

1. **AoE blanket mode** — if uncovered players ≥ `AOE_BLANKET_THRESHOLD` (3), firehose Rejuvs take priority. Exception: tank with no Regrowth ticking still gets Regrowth first.
2. **Single-target active healing** — on the highest-pressure candidate:
   - Swiftmend (non-tank only, below `SWIFTMEND_THRESHOLD`, has HoT)
   - Regrowth — tanks always; non-tanks only if pressure ≥ `REGROWTH_NON_TANK_FLOOR`
   - Rejuv — fresh cast or upgrade if warranted

### Pressure Score

Each unit's pressure score (0.0–1.0):

| Component | Contribution |
|---|---|
| HP deficit % | up to 1.0 |
| Live aggro | +0.25 |
| Aggro history | 0.0–0.25 |
| Rejuv HoT ticking | up to −0.15 |
| Regrowth HoT ticking | up to −0.20 |

Units below 20% HP receive a minimum pressure of 0.75 regardless of HoT coverage.

### Rejuv Rank Selection

```
effectiveHeal = (baseHeal + healingPower × 0.80) × irMod × gnMod
```

Walks R1→R12, picks the lowest rank whose effective heal covers the deficit. For tanks, the deficit is inflated by up to 1.20× to anticipate incoming damage. Mana gate steps down if a rank is unaffordable.

During clearcasting (Omen of Clarity), always uses max rank at no cost.

### Regrowth Rank Selection

Pressure-threshold driven:

| Pressure | Rank |
|---|---|
| ≥ 0.70 | Max rank |
| 0.55–0.70 | R7 |
| 0.35–0.55 | R5 |
| 0.15–0.35 | R3 |
| > 0 | R1 |

Mana gate steps down if a rank is unaffordable.

### HoT Clip Protection

`CastRegrowthSafe` prevents overwriting strong Regrowth HoTs with weaker ones:

- **No HoT or R1–R5** — cast freely at intended rank
- **R6–R9 HoT ticking** — cast one rank below existing to preserve ticks, unless pressure is high (≥ 0.55) or the upgrade is significant (≥ 2 ranks stronger)
- **Max rank HoT ticking** — cast one below max for a direct heal, preserving the max HoT. If intended rank is also max, refresh it

---

## GUI Windows

### `/mcdr` — Healing Style
Adjust between pulls based on fight mechanics.

| Slider | Default | Description |
|---|---|---|
| Regrowth Floor | 0.55 | Min pressure for non-tank units to receive Regrowth |
| AoE Blanket | 3 | Uncovered players needed to trigger firehose-priority mode |

### `/mcsettings` — Thresholds
Set once for your playstyle; rarely changed mid-session.

| Slider | Default | Description |
|---|---|---|
| NS threshold | 0.50 | *(reserved for future use)* |
| Rejuv threshold | 90% | HP% below which firehose/trickle Rejuvs are cast |
| Swiftmend threshold | 60% | HP% below which Swiftmend fires on non-tank units with a HoT |
| Trickle threshold | 98% | HP% below which trickle top-up Rejuvs are cast |
| Trickle mana floor | 40% | Min mana% required for trickle pass to run |
| Trickle max rank | 3 | Max Rejuv rank used during trickle (tanks bypass this) |
| Active heal threshold | 70% | HP% below which active healing mode activates |
| MoTW mana floor | 50% | Min mana% required to cast Mark of the Wild |

---

## Logging

`/mclog` records a structured entry per cast:

```
ts | unit | hp% | pressure | rejuvRank | rgRank | liveAggro | aggroScore | action | spellRank | healingPower | missingHP | isTank
```

`/mcexport` writes the buffer to `MooncallerLog.txt` (requires SuperWoW). Buffer holds up to 500 entries, drops oldest when full.

---

## Follow

`/mcl` saves the **unitid** (`party1`, `party2`, `raid1`, etc.) of your current target and calls `FollowUnit()` directly. This avoids Turtle WoW's fuzzy `/followbyname` matching.

> **Note:** Unitids are not persistent across sessions. Re-run `/mcl` after reforming a group or relogging.

---

## Configuration

All settings persist in `MooncallerDB` across sessions.

| Variable | Default | Description |
|---|---|---|
| `REJUV_THRESHOLD` | `90` | HP% below which firehose/trickle Rejuvs are cast |
| `SWIFTMEND_THRESHOLD` | `60` | HP% below which Swiftmend fires on non-tank units with a HoT |
| `TRICKLE_THRESHOLD` | `98` | HP% below which trickle top-up Rejuvs are cast |
| `TRICKLE_MAX_RANK` | `3` | Max Rejuv rank during trickle pass |
| `TRICKLE_MANA_FLOOR` | `40` | Min mana% for trickle pass to run |
| `MOTW_MANA_THRESHOLD` | `50` | Min mana% to cast Mark of the Wild |
| `AOE_BLANKET_THRESHOLD` | `3` | Uncovered players needed to enter firehose-priority mode |
| `REGROWTH_NON_TANK_FLOOR` | `0.55` | Min pressure for Regrowth on non-tank units |
| `CRITICAL_THRESHOLD` | `70` | HP% below which active healing mode activates |
| `AUTO_TREE_FORM` | `false` | Auto enter/exit Tree of Life Form on combat start/end |
| `FOLLOW_ENABLED` | `false` | Follow after `/mcheal` finds no candidates |
| `FOLLOW_TARGET_UNIT` | `nil` | Unitid of follow target (set via `/mcl`) |
