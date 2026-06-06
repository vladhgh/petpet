// PetPet — a tiny floating desktop mascot for AI coding agents.
// Reuses Codex/petdex spritesheets (~/.codex/pets/<slug>/spritesheet.webp).
// Driven by event.json written by petpet-hook.py:
//   ~/Code/petpet/event.json  {"state":"running","sleep":false,"status":"Работаю","color":"blue","detail":"file.py","ttl":0}
//
// Build: swiftc -O PetPet.swift -o petpet   (use `petpetctl build` — it re-signs)

import AppKit

// MARK: - Paths

let HOME = NSHomeDirectory()
let PETPET_DIR = HOME + "/Code/petpet"
let CONFIG_PATH = PETPET_DIR + "/config.json"
let EVENT_PATH  = PETPET_DIR + "/event.json"

// Sprite sheets live under Codex or petdex; webp preferred, png fallback.
let PET_BASES   = ["\(HOME)/.codex/pets", "\(HOME)/.petdex/pets"]
let SHEET_NAMES = ["spritesheet.webp", "spritesheet.png"]

func petSpritesheetPath(_ slug: String) -> String? {
    for base in PET_BASES {
        for name in SHEET_NAMES {
            let p = "\(base)/\(slug)/\(name)"
            if FileManager.default.fileExists(atPath: p) { return p }
        }
    }
    return nil
}

func availablePets() -> [String] {
    var slugs: Set<String> = []
    for base in PET_BASES {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: base) else { continue }
        for e in entries {
            for name in SHEET_NAMES {
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
    private var flippedCache: [ObjectIdentifier: CGImage] = [:]   // lazily mirrored frames

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

    func frame(row: Int, col: Int, flipped: Bool = false) -> CGImage? {
        guard row >= 0, row < cells.count else { return nil }
        let rowCells = cells[row]
        guard !rowCells.isEmpty else { return nil }
        let img = rowCells[min(col, rowCells.count - 1)]
        return flipped ? mirrored(img) : img
    }

    // Horizontally mirror a frame (sprites face right by default), cached by identity.
    private func mirrored(_ img: CGImage) -> CGImage {
        let key = ObjectIdentifier(img)
        if let cached = flippedCache[key] { return cached }
        let w = img.width, h = img.height
        let cs = img.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.translateBy(x: CGFloat(w), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let out = ctx.makeImage() ?? img
        flippedCache[key] = out
        return out
    }
}

// MARK: - Pet window / view

final class PetWindow: NSWindow {
    override var canBecomeKey: Bool { false }
}

final class PetView: NSView {
    weak var owner: AppDelegate?

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

    // Drag to move / toss. The pet ignores plain hover — no cursor reaction.
    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        let m = NSEvent.mouseLocation
        owner?.beginDrag(grab: NSPoint(x: m.x - win.frame.origin.x, y: m.y - win.frame.origin.y))
    }
    override func mouseDragged(with event: NSEvent) { owner?.dragTo(mouse: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent)      { owner?.releaseDrag() }

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
    enum Icon { case spinner, check, cross, question, dot }

    // Card content: a bold title (the topic), an optional soft subtitle (the
    // current activity), and a status icon on the right.
    var title = ""
    var subtitle = ""
    var detail = ""
    var detailIsCode = false
    var icon: Icon = .dot
    var accent: NSColor = .systemBlue
    var titleFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    var subFont   = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    var spinnerPhase = 0

    static let maxTextWidth: CGFloat = 140
    static let padX: CGFloat = 10
    static let padY: CGFloat = 7
    static let lineGap: CGFloat = 3
    static let codeGap: CGFloat = 5
    static let codeInsetX: CGFloat = 7
    static let codeInsetY: CGFloat = 4
    static let iconSize: CGFloat = 15
    static let iconGap: CGFloat = 10
    static let tailDX: CGFloat = 22
    static let tailDY: CGFloat = 20
    static let tailMouth: CGFloat = 14
    static let radius: CGFloat = 6
    static let drawOpts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    static let parchment = NSColor(calibratedRed: 0.965, green: 0.929, blue: 0.808, alpha: 1.0)
    static let ink       = NSColor(calibratedRed: 0.247, green: 0.180, blue: 0.110, alpha: 1.0)
    static let inkSoft   = NSColor(calibratedRed: 0.247, green: 0.180, blue: 0.110, alpha: 0.62)
    static let hairline  = NSColor(calibratedRed: 0.247, green: 0.180, blue: 0.110, alpha: 0.28)
    static let codeBg    = NSColor(calibratedRed: 0.84,  green: 0.80,  blue: 0.66,  alpha: 1.0)

    override var isFlipped: Bool { false }

    private func lineHeight(_ f: NSFont) -> CGFloat { ceil(f.ascender - f.descender + f.leading) }

    private func wrapStyle(_ mode: NSLineBreakMode) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.alignment = .left; p.lineBreakMode = mode
        return p
    }

    private func measuredH(_ s: String, font: NSFont, maxW: CGFloat) -> CGFloat {
        guard !s.isEmpty else { return 0 }
        return ceil((s as NSString).boundingRect(with: NSSize(width: maxW, height: 9999),
            options: BubbleView.drawOpts,
            attributes: [.font: font, .paragraphStyle: wrapStyle(.byWordWrapping)]).height)
    }

    private struct Metrics { var titleH, subH, detailH, codeBoxH, total: CGFloat }

    private func layoutMetrics() -> Metrics {
        let maxW = BubbleView.maxTextWidth
        let tH  = measuredH(title,    font: titleFont, maxW: maxW)
        let sH  = measuredH(subtitle, font: subFont,   maxW: maxW)
        let dW  = detailIsCode ? maxW - BubbleView.codeInsetX * 2 : maxW
        let dH  = measuredH(detail, font: subFont, maxW: dW)
        let cBH = (detail.isEmpty || !detailIsCode) ? CGFloat(0) : dH + BubbleView.codeInsetY * 2
        var tot = tH
        if sH  > 0 { tot += BubbleView.lineGap + sH }
        if cBH > 0 { tot += BubbleView.codeGap + cBH }
        else if dH > 0 { tot += BubbleView.lineGap + dH }
        return Metrics(titleH: tH, subH: sH, detailH: dH, codeBoxH: cBH, total: tot)
    }

    func fittingSize() -> NSSize {
        let m = layoutMetrics()
        let boxW = BubbleView.maxTextWidth + BubbleView.iconGap + BubbleView.iconSize + BubbleView.padX * 2
        let boxH = max(m.total, BubbleView.iconSize) + BubbleView.padY * 2
        return NSSize(width:  boxW + BubbleView.tailDX + 4,
                      height: boxH + BubbleView.tailDY + 3)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r   = BubbleView.radius
        let tDX = BubbleView.tailDX, tDY = BubbleView.tailDY, tM = BubbleView.tailMouth

        let boxRect = NSRect(x: 1, y: tDY,
                             width:  bounds.width  - tDX - 2,
                             height: bounds.height - tDY - 2)
        let minX = boxRect.minX, maxX = boxRect.maxX
        let minY = boxRect.minY, maxY = boxRect.maxY
        let bx = maxX, by = minY
        let tipX = bounds.maxX - 1, tipY: CGFloat = 2
        let outline = NSBezierPath()
        outline.move(to: NSPoint(x: minX + r, y: maxY))
        outline.line(to: NSPoint(x: maxX - r, y: maxY))
        outline.appendArc(withCenter: NSPoint(x: maxX - r, y: maxY - r),
                          radius: r, startAngle: 90, endAngle: 0, clockwise: true)
        outline.line(to: NSPoint(x: maxX, y: by + tM))
        outline.line(to: NSPoint(x: tipX, y: tipY))
        outline.line(to: NSPoint(x: bx - tM, y: minY))
        outline.line(to: NSPoint(x: minX + r, y: minY))
        outline.appendArc(withCenter: NSPoint(x: minX + r, y: minY + r),
                          radius: r, startAngle: 270, endAngle: 180, clockwise: true)
        outline.line(to: NSPoint(x: minX, y: maxY - r))
        outline.appendArc(withCenter: NSPoint(x: minX + r, y: maxY - r),
                          radius: r, startAngle: 180, endAngle: 90, clockwise: true)
        outline.close()

        BubbleView.parchment.setFill()
        outline.fill()
        BubbleView.ink.setStroke()
        outline.lineWidth = 1.5; outline.lineJoinStyle = .round; outline.stroke()

        let innerRect = boxRect.insetBy(dx: 3.5, dy: 3.5)
        let inner = NSBezierPath(roundedRect: innerRect, xRadius: max(1, r - 2), yRadius: max(1, r - 2))
        BubbleView.hairline.setStroke()
        inner.lineWidth = 1; inner.stroke()

        let m     = layoutMetrics()
        let textX = boxRect.minX + BubbleView.padX
        let maxW  = BubbleView.maxTextWidth
        var curY  = boxRect.midY + m.total / 2   // top of content block, walking downward

        let pWrap = wrapStyle(.byWordWrapping)
        let pCode = wrapStyle(.byCharWrapping)

        if m.titleH > 0 {
            let rect = NSRect(x: textX, y: curY - m.titleH, width: maxW, height: m.titleH)
            (title as NSString).draw(with: rect, options: BubbleView.drawOpts,
                attributes: [.font: titleFont, .foregroundColor: BubbleView.ink, .paragraphStyle: pWrap])
            curY -= m.titleH
        }
        if m.subH > 0 {
            curY -= BubbleView.lineGap
            let rect = NSRect(x: textX, y: curY - m.subH, width: maxW, height: m.subH)
            (subtitle as NSString).draw(with: rect, options: BubbleView.drawOpts,
                attributes: [.font: subFont, .foregroundColor: BubbleView.inkSoft, .paragraphStyle: pWrap])
            curY -= m.subH
        }
        if m.codeBoxH > 0 {
            curY -= BubbleView.codeGap
            let blockRect = NSRect(x: textX, y: curY - m.codeBoxH, width: maxW, height: m.codeBoxH)
            let bg = NSBezierPath(roundedRect: blockRect, xRadius: 3, yRadius: 3)
            BubbleView.codeBg.setFill(); bg.fill()
            BubbleView.hairline.setStroke(); bg.lineWidth = 0.8; bg.stroke()
            let codeRect = NSRect(x: textX + BubbleView.codeInsetX,
                                  y: blockRect.minY + BubbleView.codeInsetY,
                                  width: maxW - BubbleView.codeInsetX * 2,
                                  height: m.detailH)
            (detail as NSString).draw(with: codeRect, options: BubbleView.drawOpts,
                attributes: [.font: subFont, .foregroundColor: BubbleView.ink, .paragraphStyle: pCode])
        } else if m.detailH > 0 {
            curY -= BubbleView.lineGap
            let rect = NSRect(x: textX, y: curY - m.detailH, width: maxW, height: m.detailH)
            (detail as NSString).draw(with: rect, options: BubbleView.drawOpts,
                attributes: [.font: subFont, .foregroundColor: BubbleView.inkSoft, .paragraphStyle: pWrap])
        }

        let iconBox = NSRect(x: textX + maxW + BubbleView.iconGap,
                             y: boxRect.midY - BubbleView.iconSize / 2,
                             width: BubbleView.iconSize, height: BubbleView.iconSize)
        drawIcon(in: iconBox)
    }

    private func drawIcon(in b: NSRect) {
        let c = accent.blended(withFraction: 0.12, of: BubbleView.ink) ?? accent
        switch icon {
        case .check:
            let p = NSBezierPath()
            p.lineWidth = 2; p.lineCapStyle = .round; p.lineJoinStyle = .round
            p.move(to: NSPoint(x: b.minX + b.width*0.16, y: b.minY + b.height*0.52))
            p.line(to: NSPoint(x: b.minX + b.width*0.40, y: b.minY + b.height*0.26))
            p.line(to: NSPoint(x: b.minX + b.width*0.86, y: b.minY + b.height*0.78))
            c.setStroke(); p.stroke()
        case .cross:
            let p = NSBezierPath(); p.lineWidth = 2; p.lineCapStyle = .round
            p.move(to: NSPoint(x: b.minX + b.width*0.24, y: b.minY + b.height*0.24))
            p.line(to: NSPoint(x: b.maxX - b.width*0.24, y: b.maxY - b.height*0.24))
            p.move(to: NSPoint(x: b.maxX - b.width*0.24, y: b.minY + b.height*0.24))
            p.line(to: NSPoint(x: b.minX + b.width*0.24, y: b.maxY - b.height*0.24))
            c.setStroke(); p.stroke()
        case .question:
            let f = NSFont(name: "Courier New", size: b.height) ?? NSFont.boldSystemFont(ofSize: b.height)
            let bf = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask)
            let s = "?" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: bf, .foregroundColor: c]
            let sz = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: b.midX - sz.width/2, y: b.midY - sz.height/2), withAttributes: attrs)
        case .dot:
            c.setFill(); NSBezierPath(ovalIn: b.insetBy(dx: b.width*0.30, dy: b.height*0.30)).fill()
        case .spinner:
            let cx = b.midX, cy = b.midY
            let rOut = b.width * 0.46, rIn = b.width * 0.20
            let n = 8, lead = spinnerPhase % 8
            for i in 0..<n {
                let frac = CGFloat((n - 1 - ((i - lead + n) % n))) / CGFloat(n - 1)
                let ang = CGFloat(i) / CGFloat(n) * 2 * .pi
                let p = NSBezierPath(); p.lineWidth = 1.7; p.lineCapStyle = .round
                p.move(to: NSPoint(x: cx + cos(ang)*rIn,  y: cy + sin(ang)*rIn))
                p.line(to: NSPoint(x: cx + cos(ang)*rOut, y: cy + sin(ang)*rOut))
                c.withAlphaComponent(0.18 + 0.82 * frac).setStroke(); p.stroke()
            }
        }
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
    var facingLeft = false   // mirror toss/squat frames toward direction of motion

    // bubble state (raw values kept to rebuild on font change)
    var hasCard       = false
    var spinnerTimer: Timer?
    var lastTitle = "", lastStatus = "", lastDetail = "", lastColorName = "blue", lastTTL = 0.0
    var lastDetailCode = false

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
        guard hasCard else { return }
        applyCard()
    }

    // MARK: interaction

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
        // Face the direction of horizontal motion (= toward the cursor while
        // dragging, = throw direction in flight). Hysteresis avoids flicker.
        if vx < -40 { facingLeft = true }
        else if vx > 40 { facingLeft = false }
        let col = dragging ? 0 : tossFrame(vy)
        view.show(sprite.frame(row: JUMP_ROW, col: col, flipped: facingLeft))
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

    func poll() {
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
            window.animator().alphaValue = sleep ? 0.45 : 1.0   // dim = "asleep"
            updateWander()
        }
        if let s = obj["state"] as? String { setAgentState(s) }

        // bubble card — always shown while the agent works; hidden while asleep
        let title  = (obj["title"]  as? String) ?? ""
        let status = (obj["status"] as? String) ?? ""
        let detail = (obj["detail"] as? String) ?? ""
        let color      = (obj["color"]       as? String) ?? "blue"
        let ttl        = (obj["ttl"]         as? Double) ?? 0
        let detailCode = (obj["detail_code"] as? Bool)   ?? false
        if asleep || (title.isEmpty && status.isEmpty && detail.isEmpty) {
            hasCard = false
            lastTitle = ""; lastStatus = ""; lastDetail = ""; lastDetailCode = false
            bubbleWindow.orderOut(nil); stopSpinner()
        } else {
            lastTitle = title; lastStatus = status; lastDetail = detail
            lastColorName = color; lastTTL = ttl; lastDetailCode = detailCode
            hasCard = true
            applyCard()
        }
    }

    func iconFor(_ color: String) -> BubbleView.Icon {
        switch color {
        case "green": return .check       // done
        case "red":   return .cross       // error
        case "amber": return .question    // waiting for input
        case "gray":  return .dot         // asleep / idle
        default:      return .spinner     // blue / purple: working / thinking
        }
    }

    // Build the card from the last raw values and show it.
    // title = topic; subtitle = current activity (status · detail). If there is
    // no topic, the status itself becomes the title (e.g. session-start "Готов").
    func applyCard() {
        let icon = iconFor(lastColorName)
        var t   = lastTitle
        var sub = lastStatus
        if t.isEmpty { t = lastStatus; sub = "" }
        bubbleView.title    = t
        bubbleView.subtitle = sub
        bubbleView.detail       = lastDetail
        bubbleView.detailIsCode = lastDetailCode
        bubbleView.icon         = icon
        bubbleView.accent    = statusColor(lastColorName)
        bubbleView.titleFont = vintageFont(config.bubbleFont, config.bubbleFontSize + 2, bold: true)
        bubbleView.subFont   = vintageFont(config.bubbleFont, config.bubbleFontSize,     bold: false)
        bubbleView.needsDisplay = true

        bubbleHideTimer?.invalidate()
        bubbleWindow.setContentSize(bubbleView.fittingSize())
        repositionBubble()
        bubbleWindow.orderFront(nil)
        if icon == .spinner { startSpinner() } else { stopSpinner() }
        if lastTTL > 0 {
            bubbleHideTimer = Timer.scheduledTimer(withTimeInterval: lastTTL, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.bubbleWindow.orderOut(nil); self.stopSpinner()
            }
        }
    }

    func startSpinner() {
        if spinnerTimer != nil { return }
        spinnerTimer = Timer.scheduledTimer(withTimeInterval: 0.11, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.bubbleView.spinnerPhase &+= 1
            self.bubbleView.needsDisplay = true
        }
    }

    func stopSpinner() { spinnerTimer?.invalidate(); spinnerTimer = nil }

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
        return agentState == "idle" && !dragging && !tossing && !asleep
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
        guard let anim = ANIMS[playing] else { return }
        facingLeft = false   // non-toss anims always face right
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
