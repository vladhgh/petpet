// PetPet — a tiny floating desktop mascot for AI coding agents.
// Reuses Codex/petdex spritesheets (~/.codex/pets/<slug>/spritesheet.webp).
// Driven by event.json written by petpet-hook.py:
//   ~/Code/petpet/event.json  {"state":"running","sleep":false,"status":"Работаю","color":"blue","detail":"file.py","ttl":6}
//
// Build: swiftc -O PetPet.swift -o petpet   (use `petpetctl build` — it re-signs)

import AppKit

// MARK: - Paths

let HOME = NSHomeDirectory()
let PETPET_DIR = HOME + "/Code/petpet"
let CONFIG_PATH = PETPET_DIR + "/config.json"
let EVENT_PATH  = PETPET_DIR + "/event.json"

func petSpritesheetPath(_ slug: String) -> String? {
    for base in ["\(HOME)/.codex/pets", "\(HOME)/.petdex/pets"] {
        for name in ["spritesheet.webp", "spritesheet.png"] {
            let p = "\(base)/\(slug)/\(name)"
            if FileManager.default.fileExists(atPath: p) { return p }
        }
    }
    return nil
}

func availablePets() -> [String] {
    var slugs: Set<String> = []
    for base in ["\(HOME)/.codex/pets", "\(HOME)/.petdex/pets"] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
        for e in entries {
            for name in ["spritesheet.webp", "spritesheet.png"] {
                if FileManager.default.fileExists(atPath: "\(base)/\(e)/\(name)") {
                    slugs.insert(e); break
                }
            }
        }
    }
    return slugs.sorted()
}

// Retro typewriter face with monospaced-system fallback.
func vintageFont(_ name: String, _ size: CGFloat, bold: Bool) -> NSFont {
    let base = NSFont(name: name, size: size)
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
    var bubbleFont: String = "Courier New"
    var bubbleFontSize: CGFloat = 12.0

    static func load() -> Config {
        var c = Config()
        guard let data = FileManager.default.contents(atPath: CONFIG_PATH),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return c }
        if let p  = obj["pet"]            as? String { c.pet            = p }
        if let s  = obj["scale"]          as? Double { c.scale          = CGFloat(s) }
        if let x  = obj["x"]              as? Double { c.x              = CGFloat(x) }
        if let y  = obj["y"]              as? Double { c.y              = CGFloat(y) }
        if let f  = obj["bubbleFont"]     as? String { c.bubbleFont     = f }
        if let fs = obj["bubbleFontSize"] as? Double { c.bubbleFontSize = CGFloat(fs) }
        return c
    }

    func save() {
        var obj: [String: Any] = [
            "pet": pet, "scale": Double(scale),
            "bubbleFont": bubbleFont, "bubbleFontSize": Double(bubbleFontSize)
        ]
        if let x = x { obj["x"] = Double(x) }
        if let y = y { obj["y"] = Double(y) }
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: CONFIG_PATH))
        }
    }
}

// MARK: - Animation table

struct FrameSpec { let col: Int; let dur: Double }
struct AnimSpec  { let row: Int; let frames: [FrameSpec] }

let COLS = 8
let ROWS = 9
let JUMP_ROW = 4

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

    // Layer is configured once here — contentsGravity and magnificationFilter never change per frame.
    override func makeBackingLayer() -> CALayer {
        let l = CALayer()
        l.contentsGravity = .resizeAspect
        l.magnificationFilter = .nearest   // crisp pixels; faster than trilinear for pixel art
        return l
    }

    func show(_ cg: CGImage?) {
        wantsLayer = true
        layer?.contents = cg
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseEntered(with event: NSEvent) { owner?.setHover(true);  NSCursor.openHand.push() }
    override func mouseExited(with event: NSEvent)  { owner?.setHover(false); NSCursor.pop() }

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        let m = NSEvent.mouseLocation
        NSCursor.closedHand.push()
        owner?.beginDrag(grab: NSPoint(x: m.x - win.frame.origin.x, y: m.y - win.frame.origin.y))
    }
    override func mouseDragged(with event: NSEvent) { owner?.dragTo(mouse: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent)      { NSCursor.pop(); owner?.releaseDrag() }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Bigger",   action: #selector(bigger),   keyEquivalent: "+").target = self
        m.addItem(withTitle: "Smaller",  action: #selector(smaller),  keyEquivalent: "-").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Settings", action: #selector(settings), keyEquivalent: ",").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit PetPet", action: #selector(quit), keyEquivalent: "q").target = self
        return m
    }
    @objc private func bigger()   { owner?.nudgeScale(0.25) }
    @objc private func smaller()  { owner?.nudgeScale(-0.25) }
    @objc private func settings() { owner?.openSettings() }
    @objc private func quit()     { NSApp.terminate(nil) }
}

// MARK: - Status bubble

final class BubbleView: NSView {
    var content = NSAttributedString() { didSet { needsDisplay = true } }

    static let maxTextWidth: CGFloat = 300
    static let padX: CGFloat = 12
    static let padY: CGFloat = 8
    // Tail exits bottom-right corner of box at ~45° toward the pet.
    static let tailDX: CGFloat = 22    // tail horizontal extent beyond box
    static let tailDY: CGFloat = 22    // tail vertical drop below box
    static let tailMouth: CGFloat = 14 // size of tail opening at corner
    static let radius: CGFloat = 5
    static let drawOpts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    static let parchment = NSColor(calibratedRed: 0.965, green: 0.929, blue: 0.808, alpha: 1.0)
    static let ink       = NSColor(calibratedRed: 0.247, green: 0.180, blue: 0.110, alpha: 1.0)
    static let inkSoft   = NSColor(calibratedRed: 0.247, green: 0.180, blue: 0.110, alpha: 0.28)

    static func size(for content: NSAttributedString) -> NSSize {
        let b = content.boundingRect(with: NSSize(width: maxTextWidth, height: 40), options: drawOpts)
        return NSSize(width:  ceil(b.width)  + padX * 2 + tailDX + 4,
                      height: ceil(b.height) + padY * 2 + tailDY + 3)
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r   = BubbleView.radius
        let tDX = BubbleView.tailDX, tDY = BubbleView.tailDY, tM = BubbleView.tailMouth

        // Box occupies top portion; bottom tDY rows and right tDX cols reserved for tail.
        let boxRect = NSRect(x: 1, y: tDY,
                             width:  bounds.width  - tDX - 2,
                             height: bounds.height - tDY - 2)
        let box = NSBezierPath(roundedRect: boxRect, xRadius: r, yRadius: r)

        // Tail: triangle from box's bottom-right corner (~45°) to window's bottom-right.
        let bx = boxRect.maxX, by = boxRect.minY   // bottom-right of box
        let tipX = bounds.maxX - 1, tipY: CGFloat = 2
        let tail = NSBezierPath()
        tail.move(to: NSPoint(x: bx - tM, y: by))     // mouth left  (on bottom edge)
        tail.line(to: NSPoint(x: tipX,    y: tipY))    // tip
        tail.line(to: NSPoint(x: bx,      y: by + tM)) // mouth right (on right edge)
        tail.close()

        // fill box + tail
        let region = box.copy() as! NSBezierPath
        region.append(tail)
        BubbleView.parchment.setFill()
        region.fill()

        // border
        BubbleView.ink.setStroke()
        box.lineWidth = 1.5; box.stroke()
        let edges = NSBezierPath()
        edges.move(to: NSPoint(x: bx - tM, y: by))
        edges.line(to: NSPoint(x: tipX,    y: tipY))
        edges.line(to: NSPoint(x: bx,      y: by + tM))
        edges.lineWidth = 1.5; edges.stroke()

        // erase the seam at the box bottom-right corner where tail meets box border
        BubbleView.parchment.setStroke()
        let seam = NSBezierPath()
        seam.move(to: NSPoint(x: bx - tM + 1, y: by))
        seam.line(to: NSPoint(x: bx,           y: by + tM - 1))
        seam.lineWidth = 2.5; seam.stroke()

        // inner engraved hairline
        let innerRect = boxRect.insetBy(dx: 3.5, dy: 3.5)
        let inner = NSBezierPath(roundedRect: innerRect, xRadius: max(1, r - 2), yRadius: max(1, r - 2))
        BubbleView.inkSoft.setStroke()
        inner.lineWidth = 1; inner.stroke()

        let textRect = NSRect(x: BubbleView.padX,
                              y: tDY + BubbleView.padY,
                              width:  boxRect.width  - BubbleView.padX * 2,
                              height: boxRect.height - BubbleView.padY * 2)
        content.draw(with: textRect, options: BubbleView.drawOpts)
    }
}

// MARK: - Settings window

let BUBBLE_FONTS = ["Courier New", "Menlo", "Monaco", "American Typewriter", "Helvetica"]

final class SettingsWindowController: NSWindowController {
    weak var app: AppDelegate?
    private var petPopup: NSPopUpButton!
    private var fontPopup: NSPopUpButton!
    private var sizeField: NSTextField!

    convenience init(app: AppDelegate) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 152),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "PetPet Settings"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        self.init(window: panel)
        self.app = app
        buildUI()
    }

    private func makeLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func buildUI() {
        guard let v = window?.contentView else { return }

        petPopup  = NSPopUpButton()
        fontPopup = NSPopUpButton()
        sizeField = NSTextField()
        sizeField.placeholderString = "12"
        sizeField.translatesAutoresizingMaskIntoConstraints = false
        let fmt = NumberFormatter()
        fmt.minimum = 8; fmt.maximum = 24; fmt.allowsFloats = false
        sizeField.formatter = fmt

        let ptLabel = NSTextField(labelWithString: "pt")
        let sizeRow = NSStackView(views: [sizeField, ptLabel])
        sizeRow.spacing = 4; sizeRow.orientation = .horizontal; sizeRow.alignment = .centerY

        fontPopup.addItems(withTitles: BUBBLE_FONTS)
        petPopup.target  = self; petPopup.action  = #selector(petChanged)
        fontPopup.target = self; fontPopup.action = #selector(fontChanged)
        sizeField.target = self; sizeField.action = #selector(sizeChanged)

        let grid = NSGridView(views: [
            [makeLabel("Pet"),  petPopup],
            [makeLabel("Font"), fontPopup],
            [makeLabel("Size"), sizeRow],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.columnSpacing = 8; grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing

        let closeBtn = NSButton(title: "Close", target: self, action: #selector(closePanel))
        closeBtn.bezelStyle = .rounded
        closeBtn.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(grid)
        v.addSubview(closeBtn)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: v.topAnchor, constant: 16),
            grid.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            sizeField.widthAnchor.constraint(equalToConstant: 44),
            closeBtn.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            closeBtn.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -12),
        ])

        refresh()
    }

    func refresh() {
        guard let cfg = app?.config else { return }
        var pets = availablePets()
        if !pets.contains(cfg.pet) { pets.insert(cfg.pet, at: 0) }
        petPopup.removeAllItems()
        petPopup.addItems(withTitles: pets)
        if let idx = pets.firstIndex(of: cfg.pet) { petPopup.selectItem(at: idx) }
        if let idx = BUBBLE_FONTS.firstIndex(of: cfg.bubbleFont) { fontPopup.selectItem(at: idx) }
        sizeField.stringValue = "\(Int(cfg.bubbleFontSize))"
    }

    @objc private func petChanged() {
        guard let slug = petPopup.selectedItem?.title else { return }
        app?.changePet(to: slug)
    }
    @objc private func fontChanged() {
        guard let name = fontPopup.selectedItem?.title else { return }
        app?.changeBubbleFont(name: name, size: app?.config.bubbleFontSize ?? 12)
    }
    @objc private func sizeChanged() {
        let sz = CGFloat((sizeField.formatter as? NumberFormatter)?
            .number(from: sizeField.stringValue)?.doubleValue ?? 12)
        app?.changeBubbleFont(name: app?.config.bubbleFont ?? "Courier New", size: sz)
    }
    @objc private func closePanel() { window?.orderOut(nil) }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: PetWindow!
    var view: PetView!
    var bubbleWindow: NSWindow!
    var bubbleView: BubbleView!
    var sprite: Sprite!
    var config: Config!
    var settingsWC: SettingsWindowController?

    var agentState = "idle"
    var hovering   = false
    var playing    = ""
    var asleep     = false

    // toss physics
    var dragging = false
    var didMove  = false
    var px: CGFloat = 0, py: CGFloat = 0
    var vx: CGFloat = 0, vy: CGFloat = 0
    var anchorX: CGFloat = 0, anchorY: CGFloat = 0
    var grabDX: CGFloat = 0, grabDY: CGFloat = 0
    var physicsTimer: Timer?
    let physDT: CGFloat = 1.0 / 60.0
    var tossing: Bool { physicsTimer != nil }

    // bubble state (raw values kept to rebuild on font change)
    var currentContent: NSAttributedString? = nil
    var currentSticky  = false
    var lastStatus = "", lastDetail = "", lastColor = NSColor.systemBlue, lastTTL = 0.0

    // autonomous idle
    var behaviorState: String? = nil
    var wanderActive = false
    var idleScheduleTimer: Timer?
    var behaviorTimer: Timer?

    var frameIndex = 0
    var animTimer:   Timer?
    var revertTimer: Timer?
    var stateGen = 0
    var bubbleHideTimer: Timer?

    var lastEventMtime: TimeInterval = 0

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

    // MARK: settings

    func openSettings() {
        if settingsWC == nil { settingsWC = SettingsWindowController(app: self) }
        settingsWC?.refresh()
        settingsWC?.showWindow(nil)
        settingsWC?.window?.center()
    }

    func changePet(to slug: String) {
        guard config.pet != slug,
              let path = petSpritesheetPath(slug),
              let spr  = Sprite(path: path) else { return }
        sprite = spr
        config.pet = slug
        config.save()
        applyScale()
        refreshDisplay(force: true)
    }

    func changeBubbleFont(name: String, size: CGFloat) {
        config.bubbleFont     = name
        config.bubbleFontSize = max(8, min(24, size))
        config.save()
        guard currentContent != nil, !lastStatus.isEmpty || !lastDetail.isEmpty else { return }
        currentContent = statusCard(status: lastStatus, color: lastColor, detail: lastDetail)
        bubbleView.content = currentContent!
        bubbleWindow.setContentSize(BubbleView.size(for: currentContent!))
        repositionBubble()
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

    func tossFrame(_ vy: CGFloat) -> Int {
        if abs(vy) < 30 { return 0 }
        if vy > 260 { return 4 }
        if vy > 90  { return 3 }
        if vy > 30  { return 2 }
        return 1
    }

    func beginDrag(grab: NSPoint) {
        dragging = true; didMove = false
        px = window.frame.origin.x; py = window.frame.origin.y
        anchorX = px; anchorY = py
        grabDX = grab.x; grabDY = grab.y
        vx = 0; vy = 0
        startPhysics(); refreshDisplay(); updateWander()
    }

    func dragTo(mouse: NSPoint) {
        anchorX = mouse.x - grabDX; anchorY = mouse.y - grabDY
        if abs(anchorX - px) > 2 || abs(anchorY - py) > 2 { didMove = true }
    }

    func releaseDrag() { dragging = false }

    func startPhysics() {
        if physicsTimer != nil { return }
        physicsTimer = Timer.scheduledTimer(withTimeInterval: Double(physDT), repeats: true) { [weak self] _ in
            self?.physicsStep()
        }
        refreshDisplay()
    }

    func physicsStep() {
        let dt = physDT
        if dragging {
            let k: CGFloat = 620, damp: CGFloat = 26
            vx += (k * (anchorX - px) - damp * vx) * dt
            vy += (k * (anchorY - py) - damp * vy) * dt
        } else {
            vx *= 0.82; vy *= 0.82
        }
        let cap: CGFloat = 2600
        vx = max(-cap, min(cap, vx)); vy = max(-cap, min(cap, vy))
        px += vx * dt; py += vy * dt

        if let vis = NSScreen.main?.visibleFrame {
            let w = window.frame.width, h = window.frame.height
            if px < vis.minX { px = vis.minX; vx =  abs(vx) * 0.5 }
            if px > vis.maxX - w { px = vis.maxX - w; vx = -abs(vx) * 0.5 }
            if py < vis.minY { py = vis.minY; vy =  abs(vy) * 0.5 }
            if py > vis.maxY - h { py = vis.maxY - h; vy = -abs(vy) * 0.5 }
        }

        window.setFrameOrigin(NSPoint(x: px, y: py))
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
        refreshDisplay(); updateWander()
    }

    // MARK: polling (single event.json — merges state + bubble)

    func poll() { pollEvent() }

    func pollEvent() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: EVENT_PATH),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
              mtime != lastEventMtime else { return }
        lastEventMtime = mtime
        guard let data = FileManager.default.contents(atPath: EVENT_PATH),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // animation state
        let sleep = (obj["sleep"] as? Bool) ?? false
        if sleep != asleep {
            asleep = sleep
            let a: CGFloat = sleep ? 0.45 : 1.0
            window.animator().alphaValue = a
            bubbleWindow.animator().alphaValue = a
            updateWander()
        }
        if let s = obj["state"] as? String { setAgentState(s) }

        // bubble card
        let status = (obj["status"] as? String) ?? ""
        let detail = (obj["detail"] as? String) ?? (obj["text"] as? String ?? "")
        let color  = statusColor((obj["color"] as? String) ?? "blue")
        let ttl    = (obj["ttl"]    as? Double) ?? 6
        if status.isEmpty && detail.isEmpty {
            currentContent = nil; currentSticky = false
            lastStatus = ""; lastDetail = ""
            bubbleWindow.orderOut(nil)
        } else {
            lastStatus = status; lastDetail = detail; lastColor = color; lastTTL = ttl
            currentContent = statusCard(status: status, color: color, detail: detail)
            showStatus(currentContent!, ttl: ttl)
        }
    }

    func statusCard(status: String, color: NSColor, detail: String) -> NSAttributedString {
        let p   = NSMutableParagraphStyle()
        p.alignment = .left; p.lineBreakMode = .byTruncatingTail
        let ink  = NSColor(calibratedRed: 0.247, green: 0.180, blue: 0.110, alpha: 1.0)
        let soft = NSColor(calibratedRed: 0.247, green: 0.180, blue: 0.110, alpha: 0.62)
        let dot  = color.blended(withFraction: 0.18, of: ink) ?? color
        let fn   = config.bubbleFont
        let fs   = config.bubbleFontSize
        let m = NSMutableAttributedString()
        if !status.isEmpty {
            m.append(NSAttributedString(string: "● ", attributes: [
                .font: vintageFont(fn, fs, bold: true), .foregroundColor: dot, .paragraphStyle: p]))
            m.append(NSAttributedString(string: status, attributes: [
                .font: vintageFont(fn, fs + 1, bold: true), .foregroundColor: ink, .paragraphStyle: p]))
        }
        if !detail.isEmpty {
            m.append(NSAttributedString(string: "  ·  ", attributes: [
                .font: vintageFont(fn, fs, bold: false), .foregroundColor: soft, .paragraphStyle: p]))
            m.append(NSAttributedString(string: detail, attributes: [
                .font: vintageFont(fn, fs, bold: false), .foregroundColor: soft, .paragraphStyle: p]))
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
        refreshDisplay(); updateWander()
    }

    // MARK: autonomous idle

    func canWander() -> Bool {
        return agentState == "idle" && !hovering && !dragging && !tossing && !asleep
    }

    func updateWander() {
        if canWander() {
            if !wanderActive { wanderActive = true; scheduleNextBehavior() }
        } else {
            wanderActive = false; stopBehavior()
        }
    }

    func scheduleNextBehavior() {
        idleScheduleTimer?.invalidate()
        idleScheduleTimer = Timer.scheduledTimer(withTimeInterval: Double.random(in: 3.5...9.0),
                                                 repeats: false) { [weak self] _ in self?.startRandomBehavior() }
    }

    func startRandomBehavior() {
        guard canWander() else { return }
        let roll = Double.random(in: 0..<1)
        var dur = Double.random(in: 1.4...2.6)
        if      roll < 0.28 { behaviorState = "waving";  dur = 1.3 }
        else if roll < 0.58 { behaviorState = "review";  dur = 1.6 }
        else if roll < 0.78 { behaviorState = "waiting"; dur = 1.6 }
        else                { behaviorState = nil }
        refreshDisplay()
        behaviorTimer?.invalidate()
        behaviorTimer = Timer.scheduledTimer(withTimeInterval: dur, repeats: false) { [weak self] _ in
            self?.endBehavior()
        }
    }

    func endBehavior() {
        behaviorTimer?.invalidate(); behaviorState = nil; refreshDisplay()
        if canWander() { scheduleNextBehavior() }
    }

    func stopBehavior() {
        idleScheduleTimer?.invalidate(); behaviorTimer?.invalidate()
        if behaviorState != nil { behaviorState = nil; refreshDisplay() }
    }

    func resolvedState() -> String {
        if tossing              { return "toss" }
        if hovering             { return "crouch" }
        if agentState != "idle" { return agentState }
        if let b = behaviorState { return b }
        return "idle"
    }

    func refreshDisplay(force: Bool = false) {
        let s = resolvedState()
        if s == playing && !force { return }
        playing = s; frameIndex = 0
        scheduleFrame()
    }

    func scheduleFrame() {
        animTimer?.invalidate()
        if playing == "toss"   { return }
        if playing == "crouch" { view.show(sprite.frame(row: JUMP_ROW, col: 0)); return }
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
        let b   = bubbleWindow.frame.size
        // Window's bottom-right corner is the tail tip — place it just left of pet at mid-height.
        var x = pet.minX - 2 - b.width + 1
        var y = pet.midY - 2
        if let vis = NSScreen.main?.visibleFrame {
            x = min(max(x, vis.minX + 4), vis.maxX - b.width - 4)
            y = min(max(y, vis.minY + 4), vis.maxY - b.height - 4)
        }
        bubbleWindow.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
