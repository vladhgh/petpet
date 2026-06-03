// PetPet — a tiny floating desktop mascot for AI coding agents.
// Reuses Codex/petdex spritesheets (~/.codex/pets/<slug>/spritesheet.webp).
// Driven by plain files written by agent hooks:
//   ~/.petpet/state.json   {"state":"running","sleep":false}
//   ~/.petpet/bubble.json  {"status":"Working","color":"blue","detail":"PetPet.swift","ttl":6}
//
// Build: swiftc -O PetPet.swift -o petpet   (use `petpetctl build` — it re-signs)

import AppKit

// MARK: - Paths

let HOME = NSHomeDirectory()
let PETPET_DIR = HOME + "/Code/petpet"
let CONFIG_PATH = PETPET_DIR + "/config.json"
let STATE_PATH = PETPET_DIR + "/state.json"
let BUBBLE_PATH = PETPET_DIR + "/bubble.json"

func petSpritesheetPath(_ slug: String) -> String? {
    for base in ["\(HOME)/.codex/pets", "\(HOME)/.petdex/pets"] {
        for name in ["spritesheet.webp", "spritesheet.png"] {
            let p = "\(base)/\(slug)/\(name)"
            if FileManager.default.fileExists(atPath: p) { return p }
        }
    }
    return nil
}

// Retro typewriter face (Courier) with a monospaced-system fallback. Bold via trait.
func vintageFont(_ size: CGFloat, bold: Bool) -> NSFont {
    let base = NSFont(name: "Courier New", size: size)
        ?? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    if bold { return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) }
    return base
}

func statusColor(_ name: String) -> NSColor {
    switch name {
    case "green":  return .systemGreen
    case "amber":  return .systemOrange
    case "red":    return .systemRed
    case "purple": return .systemPurple
    case "gray":   return .systemGray
    default:       return .systemBlue
    }
}

// MARK: - Config

struct Config {
    var pet: String = "minatonamikaze"
    var scale: CGFloat = 2.0
    var x: CGFloat? = nil
    var y: CGFloat? = nil

    static func load() -> Config {
        var c = Config()
        guard let data = FileManager.default.contents(atPath: CONFIG_PATH),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return c }
        if let p = obj["pet"] as? String { c.pet = p }
        if let s = obj["scale"] as? Double { c.scale = CGFloat(s) }
        if let x = obj["x"] as? Double { c.x = CGFloat(x) }
        if let y = obj["y"] as? Double { c.y = CGFloat(y) }
        return c
    }

    func save() {
        var obj: [String: Any] = ["pet": pet, "scale": Double(scale)]
        if let x = x { obj["x"] = Double(x) }
        if let y = y { obj["y"] = Double(y) }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: CONFIG_PATH))
        }
    }
}

// MARK: - Animation table (mirrors petdex desktop)

struct FrameSpec { let col: Int; let dur: Double }
struct AnimSpec { let row: Int; let frames: [FrameSpec] }

let COLS = 8
let ROWS = 9
let JUMP_ROW = 4   // 5th row top-to-bottom: crouch (col 0) → airborne (cols 1–4)

func uniform(_ row: Int, _ count: Int, _ dur: Double, _ last: Double) -> AnimSpec {
    var f: [FrameSpec] = []
    for c in 0..<count {
        f.append(FrameSpec(col: c, dur: (c == count - 1 ? last : dur) / 1000.0))
    }
    return AnimSpec(row: row, frames: f)
}

let ANIMS: [String: AnimSpec] = [
    "idle": AnimSpec(row: 0, frames: [
        FrameSpec(col: 0, dur: 0.28), FrameSpec(col: 1, dur: 0.11),
        FrameSpec(col: 2, dur: 0.11), FrameSpec(col: 3, dur: 0.14),
        FrameSpec(col: 4, dur: 0.14), FrameSpec(col: 5, dur: 0.32)]),
    "running-right": uniform(1, 8, 120, 220),
    "running-left":  uniform(2, 8, 120, 220),
    "waving":        uniform(3, 4, 140, 280),
    "jumping":       uniform(4, 5, 140, 280),
    "failed":        uniform(5, 8, 140, 240),
    "waiting":       uniform(6, 6, 150, 260),
    "running":       uniform(7, 6, 120, 220),
    "review":        uniform(8, 6, 150, 280),
]

let TRANSIENT: [String: Double] = ["jumping": 0.9, "waving": 1.6, "failed": 1.6]

// MARK: - Sprite slicing

final class Sprite {
    let frameW: Int
    let frameH: Int
    private var cells: [[CGImage]] = []

    init?(path: String) {
        guard let nsimg = NSImage(contentsOfFile: path),
              let cg = nsimg.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        let fw = cg.width / COLS
        let fh = cg.height / ROWS
        frameW = fw
        frameH = fh
        for r in 0..<ROWS {
            var rowCells: [CGImage] = []
            for c in 0..<COLS {
                if let crop = cg.cropping(to: CGRect(x: c * fw, y: r * fh, width: fw, height: fh)) {
                    rowCells.append(crop)
                }
            }
            cells.append(rowCells)
        }
    }

    func frame(row: Int, col: Int) -> CGImage? {
        guard row >= 0, row < cells.count else { return nil }
        let rowCells = cells[row]
        guard !rowCells.isEmpty else { return nil }
        return rowCells[min(col, rowCells.count - 1)]
    }
}

// MARK: - Pet window / view

final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { false }
}

final class PetView: NSView {
    weak var owner: AppDelegate?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { false }

    func show(_ cg: CGImage?) {
        wantsLayer = true
        layer?.contents = cg
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .trilinear
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    // Cursor management via push/pop — reliable for floating non-key windows.
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseEntered(with event: NSEvent) {
        owner?.setHover(true)
        NSCursor.openHand.push()
    }
    override func mouseExited(with event: NSEvent) {
        owner?.setHover(false)
        NSCursor.pop()
    }

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        let m = NSEvent.mouseLocation
        NSCursor.closedHand.push()
        owner?.beginDrag(grab: NSPoint(x: m.x - win.frame.origin.x, y: m.y - win.frame.origin.y))
    }

    override func mouseDragged(with event: NSEvent) {
        owner?.dragTo(mouse: NSEvent.mouseLocation)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()   // restore openHand (we're still hovering)
        owner?.releaseDrag()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Bigger",  action: #selector(bigger),  keyEquivalent: "+").target = self
        m.addItem(withTitle: "Smaller", action: #selector(smaller), keyEquivalent: "-").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit PetPet", action: #selector(quit), keyEquivalent: "q").target = self
        return m
    }
    @objc private func bigger()  { owner?.nudgeScale(0.25) }
    @objc private func smaller() { owner?.nudgeScale(-0.25) }
    @objc private func quit()    { NSApp.terminate(nil) }
}

// MARK: - Status bubble

final class BubbleView: NSView {
    var content = NSAttributedString() { didSet { needsDisplay = true } }
    // tailY: Y position of tail tip inside the view, from bottom (points right toward pet)
    var tailY: CGFloat = 0 { didSet { needsDisplay = true } }

    static let maxTextWidth: CGFloat = 300   // single line; truncates if too long
    static let padX: CGFloat = 12
    static let padY: CGFloat = 8
    static let tailW: CGFloat = 14
    static let tailH: CGFloat = 20
    static let radius: CGFloat = 5
    static let drawOpts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    static let parchment = NSColor(calibratedRed: 0.965, green: 0.929, blue: 0.808, alpha: 1.0)
    static let ink       = NSColor(calibratedRed: 0.247, green: 0.180, blue: 0.110, alpha: 1.0)
    static let inkSoft   = NSColor(calibratedRed: 0.247, green: 0.180, blue: 0.110, alpha: 0.28)

    static func size(for content: NSAttributedString) -> NSSize {
        // measure at single-line height; width capped at maxTextWidth
        let b = content.boundingRect(with: NSSize(width: maxTextWidth, height: 40), options: drawOpts)
        return NSSize(width: ceil(b.width) + padX * 2 + tailW + 4,
                      height: ceil(b.height) + padY * 2 + 3)
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let tailW = BubbleView.tailW, tailH = BubbleView.tailH, r = BubbleView.radius
        // Box takes up the left portion; tail extends from its right edge
        let boxRect = NSRect(x: 1, y: 1, width: bounds.width - tailW - 1, height: bounds.height - 2)
        let box = NSBezierPath(roundedRect: boxRect, xRadius: r, yRadius: r)

        // Clamp tail to the straight portion of the right edge (avoiding corners)
        let ty = max(r + tailH / 2 + 2,
                     min(bounds.height - r - tailH / 2 - 2,
                         tailY > 0 ? tailY : bounds.height * 0.35))
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: boxRect.maxX, y: ty + tailH / 2))
        tail.line(to: NSPoint(x: bounds.maxX - 1, y: ty))
        tail.line(to: NSPoint(x: boxRect.maxX, y: ty - tailH / 2))
        tail.close()

        // fill
        let region = box.copy() as! NSBezierPath
        region.append(tail)
        BubbleView.parchment.setFill()
        region.fill()

        // outer border
        BubbleView.ink.setStroke()
        box.lineWidth = 1.5; box.stroke()
        let edges = NSBezierPath()
        edges.move(to: NSPoint(x: boxRect.maxX, y: ty + tailH / 2))
        edges.line(to: NSPoint(x: bounds.maxX - 1, y: ty))
        edges.line(to: NSPoint(x: boxRect.maxX, y: ty - tailH / 2))
        edges.lineWidth = 1.5; edges.stroke()
        // erase the seam between box right border and tail mouth
        BubbleView.parchment.setStroke()
        let seam = NSBezierPath()
        seam.move(to: NSPoint(x: boxRect.maxX, y: ty + tailH / 2 - 1))
        seam.line(to: NSPoint(x: boxRect.maxX, y: ty - tailH / 2 + 1))
        seam.lineWidth = 2.5; seam.stroke()

        // inner engraved hairline
        let innerRect = boxRect.insetBy(dx: 3.5, dy: 3.5)
        let inner = NSBezierPath(roundedRect: innerRect, xRadius: max(1, r - 2), yRadius: max(1, r - 2))
        BubbleView.inkSoft.setStroke()
        inner.lineWidth = 1; inner.stroke()

        let textRect = NSRect(x: BubbleView.padX, y: BubbleView.padY,
                              width: boxRect.width - BubbleView.padX * 2,
                              height: boxRect.height - BubbleView.padY * 2)
        content.draw(with: textRect, options: BubbleView.drawOpts)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: PetWindow!
    var view: PetView!
    var bubbleWindow: NSWindow!
    var bubbleView: BubbleView!
    var sprite: Sprite!
    var config: Config!

    var agentState = "idle"
    var hovering = false
    var playing = ""
    var asleep = false

    // toss physics (drag with inertia)
    var dragging = false
    var didMove = false
    var px: CGFloat = 0, py: CGFloat = 0       // current origin
    var vx: CGFloat = 0, vy: CGFloat = 0       // velocity (px/s)
    var anchorX: CGFloat = 0, anchorY: CGFloat = 0
    var grabDX: CGFloat = 0, grabDY: CGFloat = 0
    var physicsTimer: Timer?
    let physDT: CGFloat = 1.0 / 60.0
    var tossing: Bool { physicsTimer != nil }

    // status bubble
    var currentContent: NSAttributedString? = nil
    var currentSticky = false

    // autonomous idle "life"
    var behaviorState: String? = nil
    var wanderActive = false
    var idleScheduleTimer: Timer?
    var behaviorTimer: Timer?

    var frameIndex = 0
    var animTimer: Timer?
    var revertTimer: Timer?
    var stateGen = 0
    var bubbleHideTimer: Timer?

    var lastStateMtime: TimeInterval = 0
    var lastBubbleMtime: TimeInterval = 0

    func applicationDidFinishLaunching(_ note: Notification) {
        config = Config.load()
        guard let path = petSpritesheetPath(config.pet), let spr = Sprite(path: path) else {
            FileHandle.standardError.write("PetPet: no spritesheet for '\(config.pet)'\n".data(using: .utf8)!)
            NSApp.terminate(nil); return
        }
        sprite = spr
        NSApp.setActivationPolicy(.accessory)
        buildPetWindow()
        buildBubbleWindow()
        applyScale()
        refreshDisplay(force: true)
        updateWander()
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
    }

    func buildPetWindow() {
        view = PetView(); view.owner = self
        window = PetWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                           styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
    }

    func buildBubbleWindow() {
        bubbleView = BubbleView()
        bubbleWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                                styleMask: .borderless, backing: .buffered, defer: false)
        bubbleWindow.isOpaque = false
        bubbleWindow.backgroundColor = .clear
        bubbleWindow.hasShadow = true
        bubbleWindow.level = .floating
        bubbleWindow.ignoresMouseEvents = true
        bubbleWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        bubbleWindow.contentView = bubbleView
        bubbleWindow.orderOut(nil)
    }

    // MARK: scale / position

    func applyScale() {
        let w = CGFloat(sprite.frameW) * config.scale
        let h = CGFloat(sprite.frameH) * config.scale
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = config.x ?? (screen.maxX - w - 24)
        let y = config.y ?? (screen.minY + 24)
        window.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        repositionBubble()
    }

    func nudgeScale(_ delta: CGFloat) {
        config.scale = max(0.5, min(8.0, config.scale + delta))
        let center = NSPoint(x: window.frame.midX, y: window.frame.midY)
        let w = CGFloat(sprite.frameW) * config.scale
        let h = CGFloat(sprite.frameH) * config.scale
        window.setFrame(NSRect(x: center.x - w/2, y: center.y - h/2, width: w, height: h), display: true)
        config.x = window.frame.origin.x; config.y = window.frame.origin.y
        config.save(); repositionBubble()
    }

    // MARK: interaction

    func setHover(_ on: Bool) {
        hovering = on
        if on, let c = currentContent {
            bubbleHideTimer?.invalidate()
            bubbleView.content = c
            bubbleWindow.setContentSize(BubbleView.size(for: c))
            repositionBubble()
            bubbleWindow.orderFront(nil)
        } else if !on, !currentSticky {
            bubbleWindow.orderOut(nil)
        }
        refreshDisplay()
        updateWander()
    }

    // Pick a frame from the jump row by how the pet is moving, so it animates
    // with the toss: still → crouch (col 0), flung up → high air (4), falling → 1.
    func tossFrame(_ vy: CGFloat) -> Int {
        if abs(vy) < 30 { return 0 }
        if vy > 260 { return 4 }
        if vy > 90  { return 3 }
        if vy > 30  { return 2 }
        return 1
    }

    func beginDrag(grab: NSPoint) {
        dragging = true
        didMove = false
        px = window.frame.origin.x; py = window.frame.origin.y
        anchorX = px; anchorY = py
        grabDX = grab.x; grabDY = grab.y
        vx = 0; vy = 0
        startPhysics()
        refreshDisplay()
        updateWander()
    }

    func dragTo(mouse: NSPoint) {
        anchorX = mouse.x - grabDX
        anchorY = mouse.y - grabDY
        if abs(anchorX - px) > 2 || abs(anchorY - py) > 2 { didMove = true }
    }

    func releaseDrag() {
        dragging = false   // physics keeps the residual velocity → momentum glide
    }

    func startPhysics() {
        if physicsTimer != nil { return }
        physicsTimer = Timer.scheduledTimer(withTimeInterval: Double(physDT), repeats: true) { [weak self] _ in
            self?.physicsStep()
        }
        refreshDisplay()   // switch to the toss frames
    }

    func physicsStep() {
        let dt = physDT
        if dragging {
            // stiff, lightly-damped spring → snappy follow with a touch of inertia
            let k: CGFloat = 620, damp: CGFloat = 26
            vx += (k * (anchorX - px) - damp * vx) * dt
            vy += (k * (anchorY - py) - damp * vy) * dt
        } else {
            vx *= 0.82; vy *= 0.82   // friction glide after release (settles quickly)
        }
        let cap: CGFloat = 2600
        vx = max(-cap, min(cap, vx)); vy = max(-cap, min(cap, vy))
        px += vx * dt; py += vy * dt

        if let vis = NSScreen.main?.visibleFrame {
            let w = window.frame.width, h = window.frame.height
            if px < vis.minX { px = vis.minX; vx = abs(vx) * 0.5 }
            if px > vis.maxX - w { px = vis.maxX - w; vx = -abs(vx) * 0.5 }
            if py < vis.minY { py = vis.minY; vy = abs(vy) * 0.5 }
            if py > vis.maxY - h { py = vis.maxY - h; vy = -abs(vy) * 0.5 }
        }

        window.setFrameOrigin(NSPoint(x: px, y: py))
        // Crouch while held, jump frames only after release (velocity-based)
        let col = dragging ? 0 : tossFrame(vy)
        view.show(sprite.frame(row: JUMP_ROW, col: col))
        repositionBubble()

        if !dragging && abs(vx) < 7 && abs(vy) < 7 { stopPhysics() }
    }

    func stopPhysics() {
        physicsTimer?.invalidate(); physicsTimer = nil
        vx = 0; vy = 0
        if didMove {
            config.x = window.frame.origin.x; config.y = window.frame.origin.y
            config.save()
        }
        refreshDisplay()
        updateWander()
    }

    // MARK: polling

    func poll() { pollState(); pollBubble() }

    func pollState() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: STATE_PATH),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
              mtime != lastStateMtime else { return }
        lastStateMtime = mtime
        guard let data = FileManager.default.contents(atPath: STATE_PATH),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let sleep = (obj["sleep"] as? Bool) ?? false
        if sleep != asleep {
            asleep = sleep
            let a: CGFloat = sleep ? 0.45 : 1.0
            window.animator().alphaValue = a
            bubbleWindow.animator().alphaValue = a
            updateWander()
        }
        if let s = obj["state"] as? String { setAgentState(s) }
    }

    func pollBubble() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: BUBBLE_PATH),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
              mtime != lastBubbleMtime else { return }
        lastBubbleMtime = mtime
        guard let data = FileManager.default.contents(atPath: BUBBLE_PATH),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let status = (obj["status"] as? String) ?? ""
        let detail = (obj["detail"] as? String) ?? (obj["text"] as? String ?? "")
        let color = statusColor((obj["color"] as? String) ?? "blue")
        let ttl = (obj["ttl"] as? Double) ?? 6
        if status.isEmpty && detail.isEmpty {
            currentContent = nil; currentSticky = false
            bubbleWindow.orderOut(nil); return
        }
        currentContent = statusCard(status: status, color: color, detail: detail)
        showStatus(currentContent!, ttl: ttl)
    }

    func statusCard(status: String, color: NSColor, detail: String) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.alignment = .left; p.lineBreakMode = .byTruncatingTail
        let ink = NSColor(calibratedRed: 0.247, green: 0.180, blue: 0.110, alpha: 1.0)
        let soft = NSColor(calibratedRed: 0.247, green: 0.180, blue: 0.110, alpha: 0.62)
        let dot = color.blended(withFraction: 0.18, of: ink) ?? color
        let m = NSMutableAttributedString()
        if !status.isEmpty {
            m.append(NSAttributedString(string: "● ", attributes: [
                .font: vintageFont(12, bold: true), .foregroundColor: dot, .paragraphStyle: p]))
            m.append(NSAttributedString(string: status, attributes: [
                .font: vintageFont(13, bold: true), .foregroundColor: ink, .paragraphStyle: p]))
        }
        if !detail.isEmpty {
            m.append(NSAttributedString(string: "  ·  ", attributes: [
                .font: vintageFont(12, bold: false), .foregroundColor: soft, .paragraphStyle: p]))
            m.append(NSAttributedString(string: detail, attributes: [
                .font: vintageFont(12, bold: false), .foregroundColor: soft, .paragraphStyle: p]))
        }
        return m
    }

    func showStatus(_ content: NSAttributedString, ttl: Double) {
        bubbleHideTimer?.invalidate()
        bubbleView.content = content
        bubbleWindow.setContentSize(BubbleView.size(for: content))
        repositionBubble()
        bubbleWindow.orderFront(nil)
        if ttl > 0 {
            currentSticky = false
            bubbleHideTimer = Timer.scheduledTimer(withTimeInterval: ttl, repeats: false) { [weak self] _ in
                if !(self?.hovering ?? false) { self?.bubbleWindow.orderOut(nil) }
            }
        } else {
            currentSticky = true
        }
    }

    // MARK: state resolution

    func setAgentState(_ s: String) {
        let resolved = ANIMS[s] != nil ? s : "idle"
        agentState = resolved
        stateGen += 1
        let gen = stateGen
        revertTimer?.invalidate()
        if let hold = TRANSIENT[resolved] {
            revertTimer = Timer.scheduledTimer(withTimeInterval: hold, repeats: false) { [weak self] _ in
                guard let self = self, self.stateGen == gen else { return }
                self.agentState = "idle"; self.refreshDisplay(); self.updateWander()
            }
        }
        refreshDisplay()
        updateWander()
    }

    // MARK: autonomous idle "life"

    func canWander() -> Bool {
        return agentState == "idle" && !hovering && !dragging && !tossing && !asleep
    }

    func updateWander() {
        if canWander() {
            if !wanderActive { wanderActive = true; scheduleNextBehavior() }
        } else {
            wanderActive = false
            stopBehavior()
        }
    }

    func scheduleNextBehavior() {
        idleScheduleTimer?.invalidate()
        let delay = Double.random(in: 3.5...9.0)
        idleScheduleTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.startRandomBehavior()
        }
    }

    func startRandomBehavior() {
        guard canWander() else { return }
        let roll = Double.random(in: 0..<1)
        var dur = Double.random(in: 1.4...2.6)
        if roll < 0.28 {
            behaviorState = "waving"; dur = 1.3
        } else if roll < 0.58 {
            behaviorState = "review"; dur = 1.6
        } else if roll < 0.78 {
            behaviorState = "waiting"; dur = 1.6
        } else {
            behaviorState = nil   // plain idle stand
        }
        refreshDisplay()
        behaviorTimer?.invalidate()
        behaviorTimer = Timer.scheduledTimer(withTimeInterval: dur, repeats: false) { [weak self] _ in
            self?.endBehavior()
        }
    }

    func endBehavior() {
        behaviorTimer?.invalidate()
        behaviorState = nil
        refreshDisplay()
        if canWander() { scheduleNextBehavior() }
    }

    func stopBehavior() {
        idleScheduleTimer?.invalidate()
        behaviorTimer?.invalidate()
        if behaviorState != nil { behaviorState = nil; refreshDisplay() }
    }

    func resolvedState() -> String {
        if tossing { return "toss" }      // physics drives the frames directly
        if hovering { return "crouch" }   // first frame of the jump row — ready to spring
        if agentState != "idle" { return agentState }
        if let b = behaviorState { return b }
        return "idle"
    }

    func refreshDisplay(force: Bool = false) {
        let s = resolvedState()
        if s == playing && !force { return }
        playing = s
        frameIndex = 0
        scheduleFrame()
    }

    func scheduleFrame() {
        animTimer?.invalidate()
        if playing == "toss" { return }   // physicsStep() owns the frame
        if playing == "crouch" {
            view.show(sprite.frame(row: JUMP_ROW, col: 0))
            return
        }
        guard let anim = ANIMS[playing] else { return }
        let f = anim.frames[frameIndex % anim.frames.count]
        view.show(sprite.frame(row: anim.row, col: f.col))
        animTimer = Timer.scheduledTimer(withTimeInterval: f.dur, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.frameIndex = (self.frameIndex + 1) % anim.frames.count
            self.scheduleFrame()
        }
    }

    // MARK: bubble position

    func repositionBubble() {
        guard bubbleWindow != nil, window != nil else { return }
        let pet = window.frame
        let b = bubbleWindow.frame.size
        // Right edge of bubble (tail tip) sits at pet's left edge
        var x = pet.minX - b.width
        // Vertically: center bubble body around pet's upper-mid area
        var y = pet.minY + CGFloat(sprite.frameH) * config.scale * 0.45
        if let vis = NSScreen.main?.visibleFrame {
            x = min(max(x, vis.minX + 4), vis.maxX - b.width - 4)
            y = min(max(y, vis.minY + 4), vis.maxY - b.height - 4)
        }
        bubbleWindow.setFrameOrigin(NSPoint(x: x, y: y))
        // tailY: Y of tail tip within bubble coords — aligned to pet's vertical center
        bubbleView.tailY = pet.midY - y
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
