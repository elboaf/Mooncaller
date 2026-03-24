# Mooncaller

**Version:** 0.2  
**Author:** Rel  
**Client:** Turtle WoW 1.12 / SuperWoW

Druid HoT healing addon with Banzai-1.0 aggro integration, pressure-based rank selection, AoE blanket mode, and healing power scanning. Designed for raid healing with an emphasis on HoT coverage efficiency and mana conservation.

---

## Changelog

### v0.2
- **Priority tank list** — configurable named tank list (`/mctanks`) with per-tank priority boosting. Listed tanks get a +0.30 pressure score bonus and −20 effective health sort bias on top of the existing aggro system, ensuring they always float to the top of the heal queue
- **Overheal Tanks mode** — when enabled, always maintains max rank Rejuv and Regrowth on listed tanks with live aggro. Fires before all other heal logic on every keypress. Rejuv is cast first, Regrowth on the following keypress. Skips Regrowth while moving
- **Movement detection** — polls `UnitPosition` every 0.1s to detect movement. Regrowth (cast-time spell) is suppressed while moving; Rejuv and Swiftmend fire normally
- **Swiftmend rework** — moved from active healing mode into the trickle/firehose pass so it fires on every keypress as a HoT-efficiency tool rather than an emergency spell. Tanks excluded. New expiry-path: fires Swiftmend on Rejuvs within a configurable seconds-remaining window to capture ticks before expiry and keep Swiftmend on cooldown
- **Swiftmend threshold removed** — Swiftmend now gates on `REJUV_THRESHOLD` rather than a separate HP threshold. `/mcswift` command removed
- **Spell rank enable/disable** — individual Rejuv and Regrowth ranks can be disabled per-rank via `/mcdr`. Swiftmend has a master enable/disable toggle. Disabled ranks are stepped past automatically at cast time
- **QuickHeal avoidance mode** — when enabled, skips Regrowth on the lowest-pressure candidate so QuickHeal's direct heal lands there. Rejuv on that target is unaffected. Waived when only one candidate exists
- **Range check fix** — `UnitPosition` returning `nil` for a unit now correctly treats them as out of range rather than in range. Player position returning `nil` still fails open
- **GUI restructure** — three dedicated windows replacing the previous two:
  - `/mcdr` — spell rank enable/disable checkboxes (Rejuv R1–R12, Regrowth R1–R10, Swiftmend toggle)
  - `/mcsettings` — all threshold sliders merged from both old windows, plus Overheal Tanks and QuickHeal Avoidance checkboxes
  - `/mctanks` — priority tank list with Add Target, Clear All, and per-row remove buttons

### v0.1
Initial release.

---

## Features

- **Pressure scoring** — combines HP deficit, live aggro, aggro history, and existing HoT coverage into a per-unit score driving spell and rank selection
- **Priority tank list** — manually designated tanks get boosted pressure scores and sort priority over aggro-detected units. Overheal mode keeps max HoTs on them at all times while they hold aggro
- **Deficit-based Rejuv rank selection** — picks the lowest rank whose effective heal (including +healing contribution) covers the target's deficit. Tanks get an inflated deficit to anticipate incoming damage
- **Pressure-based Regrowth rank selection** — rank selected continuously by pressure score rather than static HP% bands
- **HoT clip protection** — `CastRegrowthSafe` prevents overwriting higher-rank Regrowth HoTs with weaker ones, preserving ticks while still landing a direct heal
- **AoE blanket mode** — when many players are uncovered, switches to Rejuv firehose over single-target Regrowth. Configurable threshold
- **Regrowth non-tank floor** — Regrowth is reserved for tanks and high-pressure non-tanks; other players receive Rejuv only unless they genuinely need it
- **Swiftmend efficiency pass** — fires on every keypress as a HoT-efficiency tool on any non-tank below `REJUV_THRESHOLD` with a HoT ticking. Expiry-path additionally Swiftmends Rejuvs nearing expiry to prevent wasted ticks
- **Movement awareness** — Regrowth suppressed while moving; Rejuv and Swiftmend fire normally
- **Reactive Rejuv** — max rank Rejuv pre-emptively flagged on Banzai aggro pickup, delivered on next keypress
- **Spell rank enable/disable** — individual ranks can be toggled off per spell; cast functions step down to the nearest enabled rank automatically
- **QuickHeal avoidance** — yields the lowest-HP target's Regrowth slot to QuickHeal's direct heal
- **Own healing power scanner** — tooltip-scans all 19 equipment slots, weapon oils, and active buffs. Correctly handles active vs inactive set bonuses via pattern matching
- **Talent awareness** — Improved Rejuvenation, Gift of Nature, and Moonglow modifiers applied to rank selection and mana cost calculations
- **Clearcasting detection** — Omen of Clarity proc forces max rank Rejuv at no mana cost
- **Banzai-1.0 aggro integration** — tracks tanking in real time with aggroCount reset each combat
- **Follow-by-unitid** — resolves follow target to a party/raid unitid via GUID matching, bypassing Turtle WoW fuzzy name matching
- **Heal decision logging** — structured per-cast log exportable via SuperWoW `ExportFile`

---

## Requirements

| Dependency | Notes |
|---|---|
| **SuperWoW** | Required for `UnitPosition` (range checks, movement detection) and `ExportFile` (log export) |
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
      README.md
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
| `/mcdr` | Spell rank GUI — enable/disable individual Rejuv, Regrowth, and Swiftmend |
| `/mcsettings` | Settings GUI — all thresholds, Overheal Tanks, QuickHeal Avoidance |
| `/mctanks` | Priority tank list GUI |
| `/mcaddtank [name]` | Add player to priority tank list (defaults to target) |
| `/mcremovetank [name]` | Remove player from priority tank list |
| `/mccleartanks` | Clear the entire tank list |
| `/mclisttanks` | Print current tank list to chat |
| `/mcqh` | Toggle QuickHeal avoidance |
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

1. **Overheal Tanks pass** *(if enabled)* — listed tanks with live aggro missing max Rejuv or max Regrowth get it immediately. Returns after one cast
2. **Expiry-path Swiftmend** — any non-tank with a Rejuv expiring within `SWIFTMEND_EXPIRY_WINDOW` seconds gets Swiftmend to capture remaining ticks. Returns after cast
3. **When nobody is below `CRITICAL_THRESHOLD` (70% HP):**
   - **Trickle pass** — cheap low-rank Rejuv on anyone below `TRICKLE_THRESHOLD` (98%) without a Rejuv. Requires mana ≥ `TRICKLE_MANA_FLOOR`. Tanks bypass the rank cap
   - **Firehose pass** — full rank Rejuv on anyone below `REJUV_THRESHOLD` (90%) without a Rejuv
   - **Swiftmend pass** — fires on the lowest-health non-tank below `REJUV_THRESHOLD` who already has a HoT ticking
4. **When anyone is below `CRITICAL_THRESHOLD` (70% HP):**
   - **AoE blanket mode** — if uncovered players ≥ `AOE_BLANKET_THRESHOLD` (3), firehose Rejuvs take priority. Exception: tank with no Regrowth ticking still gets Regrowth first
   - **Single-target active healing** — on the highest-pressure candidate: Regrowth (tanks always; non-tanks if pressure ≥ `REGROWTH_NON_TANK_FLOOR`), then Rejuv (fresh or upgrade)

> Regrowth is suppressed at all decision points while the player is moving.

### Pressure Score

Each unit's pressure score (0.0–1.0):

| Component | Contribution |
|---|---|
| HP deficit % | up to 1.0 |
| Live aggro | +0.25 |
| Aggro history | 0.0–0.25 |
| Listed tank bonus | +0.30 |
| Rejuv HoT ticking | up to −0.15 |
| Regrowth HoT ticking | up to −0.20 |

Units below 20% HP receive a minimum pressure of 0.75 regardless of HoT coverage.

### Rejuv Rank Selection

```
effectiveHeal = (baseHeal + healingPower × 0.80) × irMod × gnMod
```

Walks R1→R12, picks the lowest rank whose effective heal covers the deficit. For tanks, the deficit is inflated by up to 1.20× to anticipate incoming damage. Mana gate steps down if a rank is unaffordable. Disabled ranks are skipped.

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

Mana gate steps down if a rank is unaffordable. Disabled ranks are skipped. Suppressed while moving.

### HoT Clip Protection

`CastRegrowthSafe` prevents overwriting strong Regrowth HoTs with weaker ones:

- **No HoT or R1–R5** — cast freely at intended rank
- **R6–R9 HoT ticking** — cast one rank below existing to preserve ticks, unless pressure is high (≥ 0.55) or the upgrade is significant (≥ 2 ranks stronger)
- **Max rank HoT ticking** — cast one below max for a direct heal, preserving the max HoT. If intended rank is also max, refresh it

---

## GUI Windows

### `/mcdr` — Spell Ranks
Enable or disable individual ranks per spell. Disabled ranks are stepped past at cast time — the next lowest enabled rank is used instead.

- Rejuvenation R1–R12 (individual checkboxes)
- Regrowth R1–R10 (individual checkboxes)
- Swiftmend master enable/disable

### `/mcsettings` — Settings
All threshold sliders and behaviour toggles in one window.

| Setting | Default | Description |
|---|---|---|
| Rejuv threshold | 90% | HP% below which firehose/trickle Rejuvs are cast; also gates Swiftmend pass |
| Trickle threshold | 98% | HP% below which trickle top-up Rejuvs are cast |
| Trickle mana floor | 40% | Min mana% for trickle pass to run |
| Trickle max rank | 3 | Max Rejuv rank during trickle pass (tanks bypass this) |
| Active heal threshold | 70% | HP% below which active healing mode activates |
| MoTW mana floor | 50% | Min mana% to cast Mark of the Wild |
| Regrowth floor | 0.55 | Min pressure for Regrowth on non-tank units |
| AoE blanket threshold | 3 | Uncovered players needed to enter firehose-priority mode |
| Swiftmend expiry window | 3.5s | Seconds remaining on Rejuv that triggers expiry-path Swiftmend. Set 0 to disable |
| Overheal Tanks | off | Always keep max Rejuv+Regrowth on listed tanks with live aggro |
| QuickHeal Avoidance | off | Skip Regrowth on the lowest-HP target to yield to QuickHeal |

### `/mctanks` — Priority Tanks
Add and remove named priority tanks. Listed tanks receive boosted pressure scores and sort priority over aggro-detected units. Changes persist across sessions.

---

## Logging

`/mclog` records a structured entry per cast:

```
ts | unit | hp% | pressure | rejuvRank | rgRank | liveAggro | aggroScore | action | spellRank | healingPower | missingHP | isTank
```

`/mcexport` writes the buffer to `MooncallerLog.txt` (requires SuperWoW). Buffer holds up to 500 entries, drops oldest when full. Log is also auto-exported at the end of each combat encounter if logging is active.

---

## Follow

`/mcl` saves the **unitid** (`party1`, `party2`, `raid1`, etc.) of your current target and calls `FollowUnit()` directly. This avoids Turtle WoW's fuzzy `/followbyname` matching.

> **Note:** Unitids are not persistent across sessions. Re-run `/mcl` after reforming a group or relogging.

---

## Configuration

All settings persist in `MooncallerDB` across sessions.

| Variable | Default | Description |
|---|---|---|
| `REJUV_THRESHOLD` | `90` | HP% below which firehose/trickle Rejuvs are cast; also gates Swiftmend pass |
| `TRICKLE_THRESHOLD` | `98` | HP% below which trickle top-up Rejuvs are cast |
| `TRICKLE_MAX_RANK` | `3` | Max Rejuv rank during trickle pass |
| `TRICKLE_MANA_FLOOR` | `40` | Min mana% for trickle pass to run |
| `MOTW_MANA_THRESHOLD` | `50` | Min mana% to cast Mark of the Wild |
| `AOE_BLANKET_THRESHOLD` | `3` | Uncovered players needed to enter firehose-priority mode |
| `REGROWTH_NON_TANK_FLOOR` | `0.55` | Min pressure for Regrowth on non-tank units |
| `CRITICAL_THRESHOLD` | `70` | HP% below which active healing mode activates |
| `SWIFTMEND_EXPIRY_WINDOW` | `3.5` | Seconds remaining on Rejuv before expiry-path Swiftmend fires |
| `SWIFTMEND_ENABLED` | `true` | Master enable for all Swiftmend casts |
| `DISABLED_REJUV_RANKS` | `{}` | Rejuv ranks to skip, keyed by rank number |
| `DISABLED_REGROWTH_RANKS` | `{}` | Regrowth ranks to skip, keyed by rank number |
| `TANK_LIST` | `{}` | Priority tank names, keyed by name |
| `OVERHEAL_TANKS` | `false` | Always keep max Rejuv+Regrowth on listed tanks with live aggro |
| `QUICKHEAL_AVOID` | `false` | Skip Regrowth on lowest-HP target to yield to QuickHeal |
| `AUTO_TREE_FORM` | `false` | Auto enter/exit Tree of Life Form on combat start/end |
| `FOLLOW_ENABLED` | `false` | Follow after `/mcheal` finds no candidates |
| `FOLLOW_TARGET_UNIT` | `nil` | Unitid of follow target (set via `/mcl`) |
