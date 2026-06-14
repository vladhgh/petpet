# Procedural animation layer — design

Date: 2026-06-14
Status: approved (decisions delegated to assistant; params tuned by user in an interactive sandbox)

## Goal

Make the mascot feel physically alive by adding a **procedural deformation layer on
top of the existing sprite-frame animation** — continuous squash-and-stretch, a
springy landing, idle "breathing", and a lean into horizontal velocity. All of it is
a transform on the rendered sprite. The spritesheets and the frame-timing system are
not touched. We reuse the physics the app already computes during drag/toss instead
of authoring more frames.

This is "approach #3" (procedural animation over simple sprite art), chosen over
spritesheet-only (current) and skeletal/Rive (would discard the reused pixel art).

## Current state (what we build on)

- Rendering: `view.show(cg)` sets `layer.contents`; one CALayer fills the window;
  `magnificationFilter = .nearest`. ([PetPet.swift:219](../../../PetPet.swift))
- Pose animation: `scheduleFrame()` — an event-driven recursive `Timer` that picks a
  `(row, col)` cell from `ANIMS` with per-frame durations. ([PetPet.swift:1142](../../../PetPet.swift))
- Physics: `physicsStep()` — a 60 Hz `Timer` that runs **only** during drag/toss,
  moves the window, and picks a `JUMP_ROW` frame by vertical velocity via
  `jumpFrame(for:)`. ([PetPet.swift:858](../../../PetPet.swift), [:899](../../../PetPet.swift))
- The pet window is **exactly sprite-sized**. ([applyScale, PetPet.swift:789](../../../PetPet.swift))
- State priority `resolvedState()`: `toss > agentState > behaviorState > idle`. ([PetPet.swift:1128](../../../PetPet.swift))

## Design

### Two orthogonal layers

- **Pose layer (unchanged):** which `(row, col)` cell is shown. `scheduleFrame` keeps
  owning this with its irregular per-frame timings.
- **Deformation layer (new):** `scale` + `rotation` about the **feet**, applied to the
  sprite layer every tick. It multiplies onto whatever pose is shown.

Sprite cells stay discrete pixel art (no tween between cells — they are bitmaps, and
the crunch is wanted). The transform runs continuously at 60 fps on top, so motion
reads smooth even while a cell is held. The transform's **persistent state** (spring,
tilt, velocity) carries momentum across hard frame/state cuts — e.g. `toss → idle`
makes the idle cell absorb the landing and spring back instead of dead-cutting.

### Effects + tuned constants

Hard-coded `let` constants next to the existing physics constants. **No** `config.json`
or `states.json` entries — matches the project's "don't add config it doesn't need"
ethos. Values were tuned by the user in a sandbox:

| Effect | Rule (per tick, `dt`) | Constants |
|---|---|---|
| Breathing (idle only) | `b = sin(phase*1.6)*0.04`; `sy *= 1+b`; `sx *= 1 - b*0.6` | amp `0.04`, speed `1.6` |
| Velocity stretch | `st = min(\|vy\|/700, 1) * 0.22`; `sy *= 1+st`; `sx *= 1 - st*0.5` | force `0.22`, ref vel `700` |
| Landing spring | integrate `s` (below); `sy *= 1-s`; `sx *= 1 + s*0.6` | stiffness `180`, damping `12` |
| Landing impulse | on floor contact with `vy < -30`: `springV += 0.50*(-vy)*0.012` | impact `0.50` |
| Tilt | `target = clamp(vx*(12/600), ±12°)`; `rot += (target-rot)*min(1, dt*12)` | max `12°`, ref vel `600` |

Spring integration each tick: `springV += (-180*s - 12*springV)*dt; s += springV*dt;`
clamp `s ∈ [-0.6, 0.6]`. Compose `sx`/`sy` multiplicatively from base `1`, then
`spriteLayer.transform = scale(sx, sy) · rotate(rot)` about the feet anchor.

### Fork decision: **β** (transform owns squash/stretch)

During physics (drag / toss / hop) hold a **neutral cell** (`idle` col 0, flipped by
direction of motion) and let the transform produce all squash/stretch. **Remove the
`jumpFrame()` / `JUMP_ROW` velocity ladder** — it was a pre-procedural workaround that
this layer replaces. (Rejected γ: keep authored jump poses + transform → risks double
squash and leaves stretch "stepped".)

Consequence: breathing applies **only in the idle state**; spring / stretch / tilt are
driven by physics velocity, which is zero outside drag/toss. So authored agent
animations (`running`, `waiting`, `review`, `waving`) play **unchanged** — the
deformation layer is a no-op for them in v1.

### Rendering changes

- Render into an **owned `spriteLayer`** sublayer (not the view's backing layer), with
  `anchorPoint = (0.5, 0)` at the feet, so we can apply the transform without AppKit
  resetting geometry on layout. `show()` sets `spriteLayer.contents`; a new method
  sets its transform.
- **Always-on tick:** a `1/60` `Timer` running while the pet is awake (stopped while
  asleep) computes the deformation and applies it. The drag/toss physics `Timer` stays
  as-is; during a toss both run, touching different layer properties (`contents` vs
  `transform`). `CADisplayLink`/vsync is a noted future smoothness upgrade, deliberately
  not adopted now to match the file's existing `Timer` pattern.

### Window headroom (so deformation isn't clipped)

The NSWindow hard-clips its contents, so it must be larger than the sprite. Add
**transparent padding** and draw the sprite inset at bottom-center. Padding as
fractions of sprite `W`/`H`:

- `PAD_TOP = 0.55` (stretch up + spring overshoot), `PAD_BOTTOM = 0.12`,
  `PAD_SIDE = 0.32` (12° tilt about the feet shifts the head by ~`sin(12°)·H ≈ 0.21·H`).

Centralize size + sprite-rect computation in helpers used by both `applyScale` and
`nudgeScale`. Adjust physics collision to the **visual sprite rect** (not the padded
window): feet land on `vis.minY`; left/right/top clamps are inset by the padding — so
the pet still reaches the real screen edges and floor. Persisted position stays the
window origin (padding is constant, so position is stable across restarts).

## Out of scope

- **Text bubble** (being reworked separately): not removed (it's tied to the hook /
  `event.json` contract), just not accounted for in the deformation. It may sit
  slightly offset vs. the padded window until its rework.
- No `config.json` / `states.json` entries for procedural constants.
- `CADisplayLink` / vsync.
- Procedural motion for authored agent states beyond tilt (e.g. a running bob) — later.

## Known minor trade-offs

- Drag/hover hit area becomes the padded (mostly transparent) window — the pet can be
  grabbed from just outside its visible body. Acceptable for a mascot.
- `repositionBubble()` anchors to the padded window edge (bubble is out of scope).
- Spring clamp `±0.6` caps extreme deformation.

## Verification

- **Compiles + signs:** `./petpetctl.sh build` (no start/restart of the live app).
- **Visual acceptance (user):** `./petpetctl.sh restart`, then:
  - drag + toss → stretch in flight, lean into motion, squash + spring on landing;
  - idle → gentle breathing;
  - `tail -f /tmp/petpet.log` → no `OS_REASON_CODESIGNING` or crashes.
