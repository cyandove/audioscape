# Audioscape — sound framework

A notecard-driven sound layer shared by the GoL dance-floor board and the
life-spheres. You experiment with sounds by editing a notecard, not scripts.

## Pieces

| File            | Where it goes                              | Job |
|-----------------|--------------------------------------------|-----|
| `sound_bank.lsl`| root prim of the board **/** each sphere   | Reads the notecard, plays sounds on request. |
| `Sound Bank.txt`| same object's inventory (notecard)         | Maps `key -> uuid, volume, mode`. Live-editable. |

Drop both into an object. The controller script(s) stay put — they gain sound
by firing one link message.

## Storage: notecard → Linkset Data

Notecard reads are slow (async, one line at a time via `dataserver`). So the
bank parses `Sound Bank.txt` **once** into **Linkset Data** (LSD), keyed as
`sb:<key> = uuid,vol,mode;uuid,vol,mode;…`. Every play afterward is a single
synchronous `llLinksetDataRead` — no dataserver round-trip.

Because LSD persists across script resets, a reset re-reads instantly and only
re-parses the notecard when it actually changes (`CHANGED_INVENTORY`) or on an
explicit `@reload`. LSD is shared per-linkset, so the bank namespaces all its
keys under `sb:` and wipes only those on reload.

> Requires current Second Life. Some OpenSim grids don't implement LSD yet — if
> you target those, tell me and I'll swap in a script-list fallback.

## How a controller triggers a sound

The bank listens for link message number **`5001`** (`LM_SOUND`). Payload is a
key, optionally with a volume override:

```lsl
integer LM_SOUND = 5001;

llMessageLinked(LINK_THIS, LM_SOUND, "birth", NULL_KEY);       // notecard volume
llMessageLinked(LINK_THIS, LM_SOUND, "reproduce|1.0", NULL_KEY); // override to 1.0
llMessageLinked(LINK_THIS, LM_SOUND, "@stop", NULL_KEY);        // stop attached/looping
```

Use `LINK_THIS` / `LINK_ROOT` / `LINK_SET` to reach the bank in the root —
**not** `LINK_ALL_CHILDREN` (that excludes the root, per the LSL skill).

The controller never knows any UUIDs. Swapping the "birth" sound is a notecard
edit; the bank reloads on save (`CHANGED_INVENTORY`).

## The notecard format

```
key | sound_uuid | volume | mode
```

- **key** — you invent these; they're just the string the controller sends.
- **volume** — `0.0`–`1.0`, optional (default `1.0`).
- **mode** — optional (default `trigger`):
  - `trigger` — detached one-shot; keeps playing even if the object dies or
    moves. Right for `death_*`, `reproduce`, `step`.
  - `play` — attached to the prim (spatialized); a new `play` replaces the
    prim's current attached sound.
  - `loop` — ambient loop until `@stop` or another loop; e.g. a `flourish` hum.
- **Random pools** — repeat a key on multiple lines and the bank picks one at
  random each play.

## Auditioning while you tune

`sound_bank.lsl` opens an owner-only listen on channel **42**. Say in chat:

```
/42 birth
/42 reproduce|1.0
/42 @stop
```

to hear any key without wiring up a controller. Set `DEBUG_CHAN = 0` in the
script to disable it for production.

## Wiring the two projects

### Life-spheres
Each sphere is its own object, so put `sound_bank.lsl` + the notecard in every
sphere (or in the object you rez copies from — inventory carries over). In your
sphere logic, at the moment state changes:

```lsl
// entering flourishing
llMessageLinked(LINK_THIS, LM_SOUND, "flourish", NULL_KEY);   // loop starts
// leaving flourishing
llMessageLinked(LINK_THIS, LM_SOUND, "@stop", NULL_KEY);
// health threshold reached -> spawn from inventory
llMessageLinked(LINK_THIS, LM_SOUND, "reproduce", NULL_KEY);
// dying
llMessageLinked(LINK_THIS, LM_SOUND, "death_lonely", NULL_KEY);   // or death_crowded
```

Because `flourish` is a `loop` and death is a `trigger`, a dying sphere's death
sound survives the object being derezzed.

### GoL board
One bank in the root prim. Fire `step` once per generation from
`gol_board_controller.lsl`. If you want a per-generation *chord* that reflects
activity (e.g. more births = brighter), send several keyed sounds in one tick,
or map board state to different keys (`stable`, `extinct`, …).

Per-tile spatial sound (a click at each individual cell) would need a small
relay script in every tile — usually not worth the script-count/64 KB cost for
225 prims. Prefer object-center `trigger` sounds, or a handful of `play` sounds
from the root.

## LSL sound gotchas baked in

- **Preloading**: after loading (and on every reset, straight from LSD) the
  bank calls `llPreloadSound` on each distinct UUID so the first play doesn't
  stutter. (Preload is throttled ~1/sec — fine for a handful of sounds; don't
  list hundreds.)
- **`trigger` vs `play`**: only `play`/`loop` sounds can be `@stop`-ped or get
  replaced; `trigger` sounds always finish. One attached sound per prim at a
  time; triggered sounds stack.
- **Upload limits**: mono, ≤ 10 s, resampled to 44.1 kHz. For continuous beds,
  loop a seamless short clip (`loop` mode) or use parcel media/stream.
- **UUIDs need perms**: to Copy Asset UUID a sound must be full-perm to you.
```
