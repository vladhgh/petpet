# Procedural Animation Layer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a procedural deformation layer (squash/stretch, landing spring, idle breathing, velocity tilt) as a transform on the rendered sprite, over the existing sprite-frame animation, without touching the spritesheets.

**Architecture:** Render the sprite into an owned `CALayer` sublayer whose anchor is the feet. An always-on 60 Hz `Timer` composes a `scale`+`rotate` transform each tick from the physics velocity and a few spring/phase state variables, and applies it to that sublayer. The pose-selection system (`scheduleFrame`/`ANIMS`) and the drag/toss physics `Timer` are unchanged except that the toss path now holds a neutral cell (decision **β**) and injects a spring impulse on landing. The pet window gains transparent padding so the deformation isn't clipped.

**Tech Stack:** Swift / AppKit, single file `PetPet.swift`. Core Animation (`CALayer`, `CATransform3D`). Build via `./petpetctl.sh build` (swiftc + codesign).

**Verification model (read this — it overrides the skill's TDD steps):** This project has **no test harness** ([CLAUDE.md](../../../CLAUDE.md) says so) and is a GUI mascot whose behavior is visual. So each task is verified by **compiling cleanly** with `./petpetctl.sh build`, and the whole feature is accepted **visually by the user**. Do **not** add XCTest. Do **not** run `start`/`restart`/`stop` — the user has a live pet running and will restart it themselves to watch. Only run `build`.

**Reference spec:** [docs/superpowers/specs/2026-06-14-procedural-animation-design.md](../specs/2026-06-14-procedural-animation-design.md)

**Tuned constants (do not change):** breathing amp `0.04` / speed `1.6`; velocity-stretch force `0.22` / ref vel `700`; spring stiffness `180` / damping `12` / impact `0.50`; tilt max `12°` / ref vel `600`. Padding fractions: top `0.55`, bottom `0.12`, side `0.32`.

---

## File structure

Only one source file changes: **`PetPet.swift`**. No new files, no new config. The work splits into five focused edits, each independently compilable and committed:

1. Sprite sublayer + deform API (rendering foundation).
2. Padded window sizing + sprite layout wiring.
3. Procedural state, constants, and the 60 Hz tick loop.
4. Physics integration (β neutral frame, spring impulse, padded collision; remove dead `jumpFrame`/`JUMP_ROW`).
5. Sleep/wake tick control + launch start.

Tasks are ordered so the project **compiles after every task**. Tasks 1–3 add unused-but-valid code; Task 4 wires physics to it; Task 5 manages lifecycle.

---

## Task 1: Sprite sublayer + deform API in `PetView`

**Files:**
- Modify: `PetPet.swift` — `PetView` (around lines 206–222), `buildPetWindow()` (around lines 734–745).

- [ ] **Step 1: Add an owned sprite sublayer and deform/layout methods to `PetView`.**

Replace the `PetView` opening (the `weak var owner`, `isFlipped`, `makeBackingLayer`, and `show` members) with:

```swift
final class PetView: NSView {
    weak var owner: AppDelegate?

    // The sprite is drawn into this owned sublayer (not the view's backing layer) so we
    // can anchor it at the feet and apply a deformation transform every frame without
    // AppKit resetting the geometry on layout. The backing layer stays a plain container.
    let spriteLayer = CALayer()

    override var isFlipped: Bool { false }

    override func makeBackingLayer() -> CALayer {
        let container = CALayer()
        spriteLayer.contentsGravity = .resizeAspect
        spriteLayer.magnificationFilter = .nearest   // crisp pixels for pixel art
        spriteLayer.anchorPoint = CGPoint(x: 0.5, y: 0)   // feet: scale grows up, tilt pivots here
        container.addSublayer(spriteLayer)
        return container
    }

    func show(_ cg: CGImage?) {
        spriteLayer.contents = cg
    }

    // Place the sprite's natural (untransformed) box inside the padded window.
    // `rect` is in view coords (origin bottom-left, since isFlipped == false).
    func layoutSprite(rect: CGRect) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        spriteLayer.bounds = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
        spriteLayer.position = CGPoint(x: rect.midX, y: rect.minY)   // anchor (0.5,0) -> feet
        CATransaction.commit()
    }

    // Squash/stretch (sx, sy) + lean (rot in radians) about the feet anchor.
    func setDeform(sx: CGFloat, sy: CGFloat, rot: CGFloat) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var t = CATransform3DMakeScale(sx, sy, 1)
        t = CATransform3DRotate(t, rot, 0, 0, 1)
        spriteLayer.transform = t
        CATransaction.commit()
    }
```

Leave the rest of `PetView` (the `mouseDown`/`mouseDragged`/`mouseUp`/`menu` members below `show`) exactly as-is.

- [ ] **Step 2: Make the backing layer materialize at window build time.**

In `buildPetWindow()`, add `view.wantsLayer = true` right after the view is created so `makeBackingLayer()` runs (and `spriteLayer` is added) before `applyScale()` lays it out. Change:

```swift
    func buildPetWindow() {
        view = PetView(); view.owner = self
```

to:

```swift
    func buildPetWindow() {
        view = PetView(); view.owner = self
        view.wantsLayer = true   // materialize the backing layer + spriteLayer now
```

- [ ] **Step 3: Build to verify it compiles.**

Run: `./petpetctl.sh build`
Expected: completes with no `swiftc` errors (exit code 0). At this point the sprite renders via `spriteLayer` but no transform is applied yet (identity), so behavior is unchanged.

- [ ] **Step 4: Commit.**

```bash
git add PetPet.swift
git commit -m "Render sprite into an owned feet-anchored sublayer"
```

---

## Task 2: Padded window sizing + sprite layout wiring

**Files:**
- Modify: `PetPet.swift` — add padding constants near `COLS`/`ROWS` (around lines 118–120); add sizing helpers and rewrite `applyScale()` (around 789–797) and `nudgeScale()` (around 799–807).

- [ ] **Step 1: Add padding constants.**

Find:

```swift
let COLS = 8
let ROWS = 9
let JUMP_ROW = 4
```

Replace with (we will delete `JUMP_ROW` in Task 4 once its last use is gone; keep it for now so the file still compiles):

```swift
let COLS = 8
let ROWS = 9
let JUMP_ROW = 4

// Transparent padding around the sprite inside the pet window, as fractions of the
// sprite's pixel size. The window hard-clips, so deformation needs this headroom:
// top for stretch + spring overshoot, sides for the 12-degree tilt about the feet.
let PAD_TOP: CGFloat = 0.55
let PAD_BOTTOM: CGFloat = 0.12
let PAD_SIDE: CGFloat = 0.32
```

- [ ] **Step 2: Add three sizing helpers to `AppDelegate`.**

Insert these methods just above `func applyScale()`:

```swift
    // Sprite pixel size at the current scale.
    func spriteSizePx() -> CGSize {
        CGSize(width: CGFloat(sprite.frameW) * config.scale,
               height: CGFloat(sprite.frameH) * config.scale)
    }

    // Padded window size = sprite plus transparent margins.
    func windowSizePx() -> CGSize {
        let s = spriteSizePx()
        return CGSize(width:  s.width  * (1 + 2 * PAD_SIDE),
                      height: s.height * (1 + PAD_TOP + PAD_BOTTOM))
    }

    // The sprite's natural box within the window (origin bottom-left).
    func visualRectInWindow() -> CGRect {
        let s = spriteSizePx()
        return CGRect(x: PAD_SIDE * s.width, y: PAD_BOTTOM * s.height,
                      width: s.width, height: s.height)
    }
```

- [ ] **Step 3: Rewrite `applyScale()` to size the padded window and lay out the sprite.**

Replace:

```swift
    func applyScale() {
        let w = CGFloat(sprite.frameW) * config.scale
        let h = CGFloat(sprite.frameH) * config.scale
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = config.x ?? (screen.maxX - w - 24)
        let y = config.y ?? (screen.minY + 24)
        window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        repositionBubble()
    }
```

with:

```swift
    func applyScale() {
        let win = windowSizePx()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = config.x ?? (screen.maxX - win.width - 24)
        let y = config.y ?? (screen.minY + 24)
        window.setFrame(NSRect(x: x, y: y, width: win.width, height: win.height), display: true)
        view.layoutSprite(rect: visualRectInWindow())
        repositionBubble()
    }
```

- [ ] **Step 4: Rewrite `nudgeScale()` the same way (keep the centered-resize behavior).**

Replace:

```swift
    func nudgeScale(_ delta: CGFloat) {
        config.scale = max(0.5, min(8.0, config.scale + delta))
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let w = CGFloat(sprite.frameW) * config.scale
        let h = CGFloat(sprite.frameH) * config.scale
        window.setFrame(NSRect(x: center.x - w/2, y: center.y - h/2, width: w, height: h), display: true)
        config.x = window.frame.origin.x; config.y = window.frame.origin.y
        config.save(); repositionBubble()
    }
```

with:

```swift
    func nudgeScale(_ delta: CGFloat) {
        config.scale = max(0.5, min(8.0, config.scale + delta))
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let win = windowSizePx()
        window.setFrame(NSRect(x: center.x - win.width/2, y: center.y - win.height/2,
                               width: win.width, height: win.height), display: true)
        config.x = window.frame.origin.x; config.y = window.frame.origin.y
        config.save()
        view.layoutSprite(rect: visualRectInWindow())
        repositionBubble()
    }
```

- [ ] **Step 5: Build to verify it compiles.**

Run: `./petpetctl.sh build`
Expected: no `swiftc` errors. The window is now padded; the sprite sits bottom-center. (Physics edges still use the old window-based math — fixed in Task 4. That's fine for an isolated compile.)

- [ ] **Step 6: Commit.**

```bash
git add PetPet.swift
git commit -m "Pad the pet window so deformation has headroom"
```

---

## Task 3: Procedural state, constants, and the 60 Hz tick loop

**Files:**
- Modify: `PetPet.swift` — add stored properties + constants in the `AppDelegate` "toss physics" block (around 683–694); add the tick methods (place them just above `func resolvedState()`).

- [ ] **Step 1: Add procedural state vars and tuned constants.**

Find the timer field in the toss-physics block:

```swift
    var physicsTimer: Timer?
    let physDT: CGFloat = 1.0 / 60.0
```

Replace with:

```swift
    var physicsTimer: Timer?
    let physDT: CGFloat = 1.0 / 60.0

    // Procedural deformation layer (always-on tick while awake).
    var tickTimer: Timer?
    var breathPhase: CGFloat = 0
    var springS: CGFloat = 0      // impact squash displacement (+ = squashed)
    var springV: CGFloat = 0
    var tiltDeg: CGFloat = 0      // current lean, eased toward target
    let BREATH_AMP: CGFloat = 0.04, BREATH_SPEED: CGFloat = 1.6
    let SS_FORCE: CGFloat = 0.22,  SS_REF: CGFloat = 700      // velocity stretch
    let SPRING_K: CGFloat = 180,   SPRING_DAMP: CGFloat = 12, SPRING_IMPACT: CGFloat = 0.50
    let TILT_MAX: CGFloat = 12,    TILT_REF: CGFloat = 600    // degrees, px/s
```

- [ ] **Step 2: Add the tick lifecycle + per-frame compose.**

Insert just above `func resolvedState()`:

```swift
    // MARK: procedural deformation tick (60 Hz while awake)

    func startTick() {
        if tickTimer != nil { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.proceduralStep()
        }
    }

    func stopTick() {
        tickTimer?.invalidate(); tickTimer = nil
        view.setDeform(sx: 1, sy: 1, rot: 0)   // rest at identity so a sleeping pet isn't mid-squash
    }

    func proceduralStep() {
        let dt = physDT

        // Impact spring (always integrating; rings down to zero on its own).
        springV += (-SPRING_K * springS - SPRING_DAMP * springV) * dt
        springS += springV * dt
        springS = max(-0.6, min(0.6, springS))
        breathPhase += dt

        var sx: CGFloat = 1, sy: CGFloat = 1

        // Breathing: idle state only, when settled.
        let settled = !tossing && abs(vx) < 25 && abs(vy) < 25
        if playing == "idle" && settled {
            let b = sin(breathPhase * BREATH_SPEED) * BREATH_AMP
            sy *= 1 + b; sx *= 1 - b * 0.6
        }

        // Velocity stretch: nonzero only while the physics velocity is nonzero (drag/toss).
        let st = min(abs(vy) / SS_REF, 1) * SS_FORCE
        sy *= 1 + st; sx *= 1 - st * 0.5

        // Impact squash.
        sy *= 1 - springS; sx *= 1 + springS * 0.6

        // Lean into horizontal velocity, eased.
        let target = max(-TILT_MAX, min(TILT_MAX, vx * (TILT_MAX / TILT_REF)))
        tiltDeg += (target - tiltDeg) * min(1, dt * 12)

        view.setDeform(sx: sx, sy: sy, rot: tiltDeg * .pi / 180)
    }
```

- [ ] **Step 3: Build to verify it compiles.**

Run: `./petpetctl.sh build`
Expected: no `swiftc` errors. The tick isn't started yet (Task 5) and physics doesn't inject the spring yet (Task 4), so behavior is still unchanged — but everything type-checks. Confirm `tossing`, `vx`, `vy`, and `playing` are all existing `AppDelegate` members (they are: `tossing` at ~693, `vx`/`vy` at ~687, `playing` is the current-animation string).

- [ ] **Step 4: Commit.**

```bash
git add PetPet.swift
git commit -m "Add procedural deformation tick (breathing, stretch, spring, tilt)"
```

---

## Task 4: Wire physics to the deformation (decision β) + remove dead jump-frame code

**Files:**
- Modify: `PetPet.swift` — `physicsStep()` (around 899–948); delete `jumpFrame(...)` (around 858–864) and the `JUMP_ROW` constant (line ~120).

- [ ] **Step 1: Replace the collision + render block in `physicsStep()`.**

In `physicsStep()`, find the block that starts at `var onFloor = true` and runs through the `view.show(...)`/`repositionBubble()` lines:

```swift
        var onFloor = true
        if let vis = NSScreen.main?.visibleFrame {
            let w = window.frame.width, h = window.frame.height
            let bounce: CGFloat = 0.5                 // restitution off the edges
            if px < vis.minX     { px = vis.minX;     vx =  abs(vx) * bounce }
            if px > vis.maxX - w { px = vis.maxX - w; vx = -abs(vx) * bounce }
            if py > vis.maxY - h { py = vis.maxY - h; vy = -abs(vy) * bounce }
            if py < vis.minY {                        // land on the floor (no bounce)
                py = vis.minY
                vy = 0
                vx *= 0.78                            // ground friction while skidding to rest
            }
            onFloor = py <= vis.minY + 1
        }

        window.setFrameOrigin(NSPoint(x: px, y: py))
        // Face the direction of horizontal motion (= toward the cursor while
        // dragging, = throw direction in flight). Hysteresis avoids flicker.
        if vx < -40 { facingLeft = true }
        else if vx > 40 { facingLeft = false }
        let col = jumpFrame(for: vy)
        view.show(sprite.frame(row: JUMP_ROW, col: col, flipped: facingLeft))
        repositionBubble()
```

Replace it with (collision now keys off the **visual sprite rect**, not the padded window; landing injects the spring; the pose is a single neutral cell — the transform does the squash/stretch):

```swift
        var onFloor = true
        let rect = visualRectInWindow()          // sprite box within the padded window
        let s = spriteSizePx()
        if let vis = NSScreen.main?.visibleFrame {
            let bounce: CGFloat = 0.5            // restitution off the edges
            let leftLimit  = vis.minX - rect.minX
            let rightLimit = vis.maxX - rect.minX - s.width
            let floorLimit = vis.minY - rect.minY
            let topLimit   = vis.maxY - rect.minY - s.height
            if px < leftLimit  { px = leftLimit;  vx =  abs(vx) * bounce }
            if px > rightLimit { px = rightLimit; vx = -abs(vx) * bounce }
            if py > topLimit   { py = topLimit;   vy = -abs(vy) * bounce }
            if py < floorLimit {                 // land on the floor (no bounce)
                if vy < -30 { springV += SPRING_IMPACT * (-vy) * 0.012 }   // impact -> squash
                py = floorLimit
                vy = 0
                vx *= 0.78                        // ground friction while skidding to rest
            }
            onFloor = py <= floorLimit + 1
        }

        window.setFrameOrigin(NSPoint(x: px, y: py))
        // Face the direction of horizontal motion. Hysteresis avoids flicker.
        if vx < -40 { facingLeft = true }
        else if vx > 40 { facingLeft = false }
        // Decision beta: hold a neutral cell; the deformation tick does all squash/stretch + lean.
        view.show(sprite.frame(row: 0, col: 0, flipped: facingLeft))
        repositionBubble()
```

- [ ] **Step 2: Delete the now-unused `jumpFrame(...)` method.**

Find and delete the whole method:

```swift
    func jumpFrame(for verticalVelocity: CGFloat) -> Int {
        if abs(verticalVelocity) < 30 { return 0 }
        if verticalVelocity > 260 { return 4 }
        if verticalVelocity > 90  { return 3 }
        if verticalVelocity > 30  { return 2 }
        return 1
    }
```

- [ ] **Step 3: Delete the now-unused `JUMP_ROW` constant.**

Find:

```swift
let COLS = 8
let ROWS = 9
let JUMP_ROW = 4
```

Replace with:

```swift
let COLS = 8
let ROWS = 9
```

(`ANIMS["jumping"]` uses the literal row `4`, not `JUMP_ROW`, so removing the constant is safe. If `./petpetctl.sh build` reports `JUMP_ROW` still referenced anywhere, search for it with `grep -n JUMP_ROW PetPet.swift` and remove that last use before continuing.)

- [ ] **Step 4: Build to verify it compiles.**

Run: `./petpetctl.sh build`
Expected: no `swiftc` errors, no "unresolved identifier `jumpFrame`/`JUMP_ROW`" warnings. Physics now renders a neutral cell and injects the spring on landing; edges/floor are computed from the visual rect.

- [ ] **Step 5: Commit.**

```bash
git add PetPet.swift
git commit -m "Toss holds a neutral cell; transform owns squash/stretch (decision beta)"
```

---

## Task 5: Start the tick on launch; stop/restart it on sleep/wake

**Files:**
- Modify: `PetPet.swift` — `applicationDidFinishLaunching(...)` (around 717–732); the two sleep-transition sites in `poll()` (the `if sleep != asleep { ... }` block ~973–978 and the `sleepAfterTimer` closure ~985–992).

- [ ] **Step 1: Start the tick at launch.**

In `applicationDidFinishLaunching`, find:

```swift
        applyScale()
        refreshDisplay(force: true)
        updateWander()
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
```

Replace with:

```swift
        applyScale()
        refreshDisplay(force: true)
        updateWander()
        startTick()
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
```

- [ ] **Step 2: Stop/restart the tick when the pet sleeps or wakes.**

In `poll()`, find the sleep-toggle block:

```swift
        let sleep = (obj["sleep"] as? Bool) ?? false
        if sleep != asleep {
            asleep = sleep
            window.animator().alphaValue = sleep ? 0.45 : 1.0   // dim = "asleep"
            updateWander()
        }
```

Replace with:

```swift
        let sleep = (obj["sleep"] as? Bool) ?? false
        if sleep != asleep {
            asleep = sleep
            window.animator().alphaValue = sleep ? 0.45 : 1.0   // dim = "asleep"
            updateWander()
            if sleep { stopTick() } else { startTick() }        // pause deformation while asleep
        }
```

- [ ] **Step 3: Stop the tick in the delayed-sleep path.**

In `poll()`, find the `sleepAfterTimer` closure body:

```swift
            sleepAfterTimer = Timer.scheduledTimer(withTimeInterval: sleepAfter, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.asleep = true
                self.window.animator().alphaValue = 0.45
                self.hasCard = false
                self.bubbleWindow.orderOut(nil); self.stopSpinner()
                self.updateWander()
            }
```

Replace with:

```swift
            sleepAfterTimer = Timer.scheduledTimer(withTimeInterval: sleepAfter, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.asleep = true
                self.window.animator().alphaValue = 0.45
                self.hasCard = false
                self.bubbleWindow.orderOut(nil); self.stopSpinner()
                self.updateWander()
                self.stopTick()
            }
```

- [ ] **Step 4: Build to verify it compiles.**

Run: `./petpetctl.sh build`
Expected: no `swiftc` errors. Feature is now fully wired: tick runs while awake, pauses on sleep, resumes on wake.

- [ ] **Step 5: Commit.**

```bash
git add PetPet.swift
git commit -m "Run the deformation tick while awake, pause it while asleep"
```

---

## Task 6: Final verification

- [ ] **Step 1: Clean build from scratch.**

Run: `./petpetctl.sh build`
Expected: exit code 0, no errors or warnings.

- [ ] **Step 2: Confirm no dead references remain.**

Run: `grep -n -E "jumpFrame|JUMP_ROW" PetPet.swift`
Expected: no output.

- [ ] **Step 3: Report for visual acceptance.**

Do **not** restart the app yourself. Report completion and tell the user to run:

```sh
./petpetctl.sh restart
tail -f /tmp/petpet.log
```

and check: drag + toss → stretch in flight, lean into motion, squash + spring rebound on landing; idle → gentle breathing; no `OS_REASON_CODESIGNING` or crashes in the log. List anything that felt off (e.g. clipping at screen top during a big toss, or the resting position shifting by the padding) so constants (`PAD_*`, spring, stretch) can be tuned.

---

## Self-review notes

- **Spec coverage:** two-layer model (Tasks 1, 3) · feet anchor (Task 1) · all four effects with tuned constants (Task 3) · decision β / neutral cell + remove `jumpFrame` ladder (Task 4) · landing spring impulse (Task 4) · always-on tick, paused on sleep (Tasks 3, 5) · window padding + visual-rect collision (Tasks 2, 4) · no config/states.json entries (constants are hard-coded `let`s, Tasks 2–3). All covered.
- **Out of scope honored:** bubble untouched; no `CADisplayLink`; no procedural motion for authored agent states (breathing gated to `playing == "idle"`).
- **Type consistency:** helper names used identically across tasks — `spriteSizePx()`, `windowSizePx()`, `visualRectInWindow()`, `view.layoutSprite(rect:)`, `view.setDeform(sx:sy:rot:)`, `view.show(_:)`, `startTick()`/`stopTick()`/`proceduralStep()`. State vars `springS`/`springV`/`tiltDeg`/`breathPhase` and constants `SPRING_*`/`SS_*`/`BREATH_*`/`TILT_*`/`PAD_*` defined once (Tasks 2–3) and referenced consistently (Tasks 3–4).
- **Known minor (documented in spec):** saved position is the window origin, so after the padding change the pet may appear shifted once — the user can drag it back; it then persists.
