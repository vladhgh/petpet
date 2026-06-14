// PetPet — a tiny floating desktop mascot for AI coding agents.
// Reuses Codex/petdex spritesheets (~/.codex/pets/<slug>/spritesheet.webp).
// Driven by event.json written by petpet-hook.py:
//   ~/.petpet/event.json  {"state":"running","sleep":false,"status":"Работаю","color":"blue","detail":"file.py","ttl":0}
// Optional "sleep_after": N keeps this card up, then dozes the pet after N seconds.
//
// Build: swiftc -O PetPet.swift -o petpet   (use `petpetctl build` — it re-signs)

import AppKit

// MARK: - Paths

let HOME = NSHomeDirectory()
let PETPET_DIR = HOME + "/.petpet"
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
    var bubbleWidth: CGFloat = 140.0     // text-column width of the card
    var bubbleExpanded: Bool = false     // false = collapsed (status only, no topic caption)
    var bubbleOffsetX: CGFloat = 0       // nudge the card off its auto position
    var bubbleOffsetY: CGFloat = 0

    static func load() -> Config {
        var c = Config()
        guard let data = FileManager.default.contents(atPath: CONFIG_PATH),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return c }
        if let p  = obj["pet"]            as? String { c.pet            = p }
        if let s  = obj["scale"]          as? Double { c.scale          = CGFloat(s) }
        if let x  = obj["x"]              as? Double { c.x              = CGFloat(x) }
        if let y  = obj["y"]              as? Double { c.y              = CGFloat(y) }
        if let f  = obj["bubbleFont"]      as? String { c.bubbleFont      = f }
        if let fs = obj["bubbleFontSize"]  as? Double { c.bubbleFontSize  = CGFloat(fs) }
        if let w  = obj["bubbleWidth"]     as? Double { c.bubbleWidth     = CGFloat(w) }
        if let ex = obj["bubbleExpanded"]  as? Bool   { c.bubbleExpanded  = ex }
        if let ox = obj["bubbleOffsetX"]   as? Double { c.bubbleOffsetX   = CGFloat(ox) }
        if let oy = obj["bubbleOffsetY"]   as? Double { c.bubbleOffsetY   = CGFloat(oy) }
        return c
    }

    func save() {
        var obj: [String: Any] = [
            "pet": pet, "scale": Double(scale),
            "bubbleFont": bubbleFont, "bubbleFontSize": Double(bubbleFontSize),
            "bubbleWidth": Double(bubbleWidth), "bubbleExpanded": bubbleExpanded,
            "bubbleOffsetX": Double(bubbleOffsetX), "bubbleOffsetY": Double(bubbleOffsetY)
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

// Transparent padding around the sprite inside the pet window, as fractions of the
// sprite's pixel size. The window hard-clips, so deformation needs this headroom:
// top for stretch + spring overshoot, sides for the 12-degree tilt about the feet.
let PAD_TOP: CGFloat = 0.55
let PAD_BOTTOM: CGFloat = 0.12
let PAD_SIDE: CGFloat = 0.32

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
        // Disable the implicit ~0.25s cross-fade Core Animation adds on `contents`.
        // This is our own sublayer (not NSView's auto-backing layer), so it doesn't
        // inherit the view delegate's "no implicit animation" behaviour — without this
        // the per-frame sprite swaps fade into each other and the animation looks frozen.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        spriteLayer.contents = cg
        CATransaction.commit()
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

    // Drag to move / toss. The grabbing (closed-hand) cursor is set here because
    // during a drag our app has the mouse captured, so set() sticks. The hover
    // (open-hand) cursor can't be done from a tracking area — this window can't
    // become key, so cursorUpdate never fires — so it lives in a global mouse
    // monitor in AppDelegate (see installCursorMonitor).
    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        NSCursor.closedHand.set()
        let m = NSEvent.mouseLocation
        owner?.beginDrag(grab: NSPoint(x: m.x - win.frame.origin.x, y: m.y - win.frame.origin.y))
    }
    override func mouseDragged(with event: NSEvent) {
        NSCursor.closedHand.set()
        owner?.dragTo(mouse: NSEvent.mouseLocation)
    }
    override func mouseUp(with event: NSEvent) {
        owner?.releaseDrag()
        NSCursor.openHand.set()
    }

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

    // Card content: a bold status line (the current activity) is the focus, an
    // optional detail line/code box below it, a status icon on the right, and —
    // only when expanded — a small soft topic caption above (the first message).
    var caption = ""                  // topic / first session message; expanded-only
    var status = ""                   // current activity — the primary line
    var detail = ""
    var detailIsCode = false
    var expanded = false
    var icon: Icon = .dot
    var accent: NSColor = .systemBlue
    var statusFont  = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    var captionFont = NSFont.monospacedSystemFont(ofSize: 9,  weight: .regular)
    var detailFont  = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    var spinnerPhase = 0
    var maxTextWidth: CGFloat = 140   // text-column width (configurable)

    // The expand/collapse chevron is the only interactive part of the bubble
    // (hitTest passes everything else through). onToggle flips config.bubbleExpanded.
    var onToggle: (() -> Void)?
    private var toggleRect: NSRect = .zero

    static let padX: CGFloat = 10
    static let padY: CGFloat = 7
    static let lineGap: CGFloat = 3
    static let codeGap: CGFloat = 5
    static let codeInsetX: CGFloat = 7
    static let codeInsetY: CGFloat = 4
    static let iconSize: CGFloat = 15
    static let iconGap: CGFloat = 10
    static let toggleSize: CGFloat = 13
    static let toggleGap: CGFloat = 5
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

    private func singleLineH(_ f: NSFont) -> CGFloat { ceil(f.ascender - f.descender + f.leading) }

    private func measuredAttrH(_ s: NSAttributedString, maxW: CGFloat) -> CGFloat {
        guard s.length > 0 else { return 0 }
        let m = NSMutableAttributedString(attributedString: s)
        m.addAttribute(.paragraphStyle, value: wrapStyle(.byWordWrapping),
                       range: NSRange(location: 0, length: m.length))
        return ceil(m.boundingRect(with: NSSize(width: maxW, height: 9999), options: BubbleView.drawOpts).height)
    }

    // The first-session-message caption, marked with guillemets so it reads as a
    // quoted request, kept to one truncated line.
    private var captionText: String { caption.isEmpty ? "" : "«\(caption)»" }

    // Primary line: bold status, plus a plain detail (filename/pattern) inlined
    // right after it to stay compact. A code detail (Bash) is NOT inlined — it
    // gets its own boxed block below.
    private func primaryAttr() -> NSAttributedString {
        let s = NSMutableAttributedString(string: status,
            attributes: [.font: statusFont, .foregroundColor: BubbleView.ink])
        if !detail.isEmpty && !detailIsCode {
            s.append(NSAttributedString(string: "  " + detail,
                attributes: [.font: detailFont, .foregroundColor: BubbleView.inkSoft]))
        }
        return s
    }

    private struct Metrics { var captionH, statusH, detailH, codeBoxH, total: CGFloat }

    private func layoutMetrics() -> Metrics {
        let maxW = maxTextWidth
        let cH  = (expanded && !caption.isEmpty) ? singleLineH(captionFont) : 0
        let sH  = measuredAttrH(primaryAttr(), maxW: maxW)   // status (+ inline detail)
        let dW  = maxW - BubbleView.codeInsetX * 2
        let dH  = detailIsCode ? measuredH(detail, font: detailFont, maxW: dW) : 0
        let cBH = (detailIsCode && !detail.isEmpty) ? dH + BubbleView.codeInsetY * 2 : 0
        var tot = sH
        if cH  > 0 { tot += cH + BubbleView.lineGap }   // caption sits above the status
        if cBH > 0 { tot += BubbleView.codeGap + cBH }
        return Metrics(captionH: cH, statusH: sH, detailH: dH, codeBoxH: cBH, total: tot)
    }

    func fittingSize() -> NSSize {
        let m = layoutMetrics()
        let boxW = maxTextWidth + BubbleView.iconGap + BubbleView.iconSize + BubbleView.padX * 2
        let gutterH = BubbleView.iconSize + BubbleView.toggleGap + BubbleView.toggleSize
        let boxH = max(m.total, gutterH) + BubbleView.padY * 2
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
        let maxW  = maxTextWidth
        var curY  = boxRect.midY + m.total / 2   // top of content block, walking downward

        let pWrap  = wrapStyle(.byWordWrapping)
        let pCode  = wrapStyle(.byCharWrapping)
        let pClip  = wrapStyle(.byTruncatingTail)

        if m.captionH > 0 {
            let rect = NSRect(x: textX, y: curY - m.captionH, width: maxW, height: m.captionH)
            (captionText as NSString).draw(with: rect, options: BubbleView.drawOpts,
                attributes: [.font: captionFont, .foregroundColor: BubbleView.inkSoft, .paragraphStyle: pClip])
            curY -= m.captionH + BubbleView.lineGap
        }
        if m.statusH > 0 {
            let attr = NSMutableAttributedString(attributedString: primaryAttr())
            attr.addAttribute(.paragraphStyle, value: pWrap, range: NSRange(location: 0, length: attr.length))
            let rect = NSRect(x: textX, y: curY - m.statusH, width: maxW, height: m.statusH)
            attr.draw(with: rect, options: BubbleView.drawOpts)
            curY -= m.statusH
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
                attributes: [.font: detailFont, .foregroundColor: BubbleView.ink, .paragraphStyle: pCode])
        }

        // Right gutter: status icon pinned to the bottom, expand/collapse chevron
        // to the top. Both share the same column so they never collide with text.
        let gutterX = textX + maxW + BubbleView.iconGap
        let iconBox = NSRect(x: gutterX, y: boxRect.minY + BubbleView.padY,
                             width: BubbleView.iconSize, height: BubbleView.iconSize)
        drawIcon(in: iconBox)

        let tS = BubbleView.toggleSize
        toggleRect = NSRect(x: gutterX + (BubbleView.iconSize - tS) / 2,
                            y: boxRect.maxY - BubbleView.padY - tS,
                            width: tS, height: tS)
        drawToggle(in: toggleRect)
    }

    private func drawToggle(in b: NSRect) {
        let bg = NSBezierPath(roundedRect: b, xRadius: 3, yRadius: 3)
        BubbleView.codeBg.setFill(); bg.fill()
        BubbleView.hairline.setStroke(); bg.lineWidth = 0.8; bg.stroke()
        let p = NSBezierPath(); p.lineWidth = 1.4; p.lineCapStyle = .round; p.lineJoinStyle = .round
        let cx = b.midX, cy = b.midY, dx = b.width * 0.22, dy = b.height * 0.13
        if expanded {                                   // ⌃ — collapse
            p.move(to: NSPoint(x: cx - dx, y: cy - dy))
            p.line(to: NSPoint(x: cx,      y: cy + dy))
            p.line(to: NSPoint(x: cx + dx, y: cy - dy))
        } else {                                        // ⌄ — expand
            p.move(to: NSPoint(x: cx - dx, y: cy + dy))
            p.line(to: NSPoint(x: cx,      y: cy - dy))
            p.line(to: NSPoint(x: cx + dx, y: cy + dy))
        }
        BubbleView.ink.setStroke(); p.stroke()
    }

    // Only the chevron is clickable; the rest of the bubble stays click-through.
    override func hitTest(_ point: NSPoint) -> NSView? {
        return toggleRect.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onToggle?() }

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
    private var widthField: NSTextField!
    private var offXField: NSTextField!
    private var offYField: NSTextField!

    convenience init(app: AppDelegate) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 220),
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

    // A small integer text field wired to `action`, clamped by [min, max].
    private func numField(min: Double, max: Double, action: Selector) -> NSTextField {
        let f = NSTextField()
        f.translatesAutoresizingMaskIntoConstraints = false
        let fmt = NumberFormatter()
        fmt.minimum = NSNumber(value: min); fmt.maximum = NSNumber(value: max)
        fmt.allowsFloats = false
        f.formatter = fmt
        f.target = self; f.action = action
        f.widthAnchor.constraint(equalToConstant: 44).isActive = true
        return f
    }

    private func buildUI() {
        guard let v = window?.contentView else { return }

        petPopup  = NSPopUpButton()
        fontPopup = NSPopUpButton()
        fontPopup.addItems(withTitles: BUBBLE_FONTS)
        petPopup.target  = self; petPopup.action  = #selector(petChanged)
        fontPopup.target = self; fontPopup.action = #selector(fontChanged)

        sizeField      = numField(min: 8,    max: 24,  action: #selector(sizeChanged))
        widthField     = numField(min: 60,   max: 400, action: #selector(widthChanged))
        offXField      = numField(min: -2000, max: 2000, action: #selector(offsetChanged))
        offYField      = numField(min: -2000, max: 2000, action: #selector(offsetChanged))

        func row(_ field: NSTextField, _ unit: String) -> NSStackView {
            let r = NSStackView(views: [field, NSTextField(labelWithString: unit)])
            r.spacing = 4; r.orientation = .horizontal; r.alignment = .centerY
            return r
        }
        let offsetRow = NSStackView(views: [
            offXField, NSTextField(labelWithString: "x"),
            offYField, NSTextField(labelWithString: "y")])
        offsetRow.spacing = 4; offsetRow.orientation = .horizontal; offsetRow.alignment = .centerY

        let grid = NSGridView(views: [
            [makeLabel("Pet"),    petPopup],
            [makeLabel("Font"),   fontPopup],
            [makeLabel("Size"),   row(sizeField, "pt")],
            [makeLabel("Width"),  row(widthField, "px")],
            [makeLabel("Offset"), offsetRow],
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
        sizeField.stringValue      = "\(Int(cfg.bubbleFontSize))"
        widthField.stringValue     = "\(Int(cfg.bubbleWidth))"
        offXField.stringValue      = "\(Int(cfg.bubbleOffsetX))"
        offYField.stringValue      = "\(Int(cfg.bubbleOffsetY))"
    }

    private func intValue(_ f: NSTextField) -> Int {
        (f.formatter as? NumberFormatter)?.number(from: f.stringValue)?.intValue
            ?? Int(f.stringValue) ?? 0
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
        app?.changeBubbleFont(name: app?.config.bubbleFont ?? "Courier New",
                              size: CGFloat(intValue(sizeField)))
    }
    @objc private func widthChanged()     { app?.changeBubbleWidth(CGFloat(intValue(widthField))) }
    @objc private func offsetChanged() {
        app?.changeBubbleOffset(x: CGFloat(intValue(offXField)), y: CGFloat(intValue(offYField)))
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

    // hover cursor (open hand over the pet); driven by a global mouse monitor
    var cursorOverPet = false

    // toss physics
    var dragging = false
    var didMove  = false
    var dragUnpinned = false
    var px: CGFloat = 0, py: CGFloat = 0
    var vx: CGFloat = 0, vy: CGFloat = 0
    var thrown = false   // in gravity flight after a real toss (vs. gentle drop)
    var settlingDrop = false
    var settleTargetY: CGFloat = 0
    var anchorX: CGFloat = 0, anchorY: CGFloat = 0
    var grabDX: CGFloat = 0, grabDY: CGFloat = 0
    var physicsActive = false
    let MAX_DT: CGFloat = 1.0 / 30.0   // clamp dt so one dropped frame can't make physics jump

    // Animation driver. Physics + deformation both run off ONE CADisplayLink, not
    // NSTimers: this process is an .accessory app whose NSTimers macOS coalesces down
    // to ~23 Hz, which (with a fixed timestep) made drags/tosses play in slow motion.
    // A display link fires at the real refresh rate and is immune to that throttling.
    var displayLink: CADisplayLink?
    var lastFrameT: CFTimeInterval = 0
    var breathPhase: CGFloat = 0
    var springS: CGFloat = 0      // impact squash displacement (+ = squashed)
    var springV: CGFloat = 0
    var tiltDeg: CGFloat = 0      // current lean, eased toward target
    let BREATH_AMP: CGFloat = 0.025, BREATH_SPEED: CGFloat = 1.6
    let SS_FORCE: CGFloat = 0.10,  SS_REF: CGFloat = 900      // velocity stretch
    let SPRING_K: CGFloat = 180,   SPRING_DAMP: CGFloat = 18, SPRING_IMPACT: CGFloat = 0.22
    let DEFORM_MIN_SX: CGFloat = 0.94, DEFORM_MAX_SX: CGFloat = 1.10
    let DEFORM_MIN_SY: CGFloat = 0.84, DEFORM_MAX_SY: CGFloat = 1.12
    let TILT_MAX: CGFloat = 12,    TILT_REF: CGFloat = 600    // degrees, px/s
    var tossing: Bool { physicsActive }
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
    var sleepAfterTimer: Timer?   // delayed sleep after a "finished" card

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
        installCursorMonitor()
        buildBubbleWindow()
        applyScale()
        refreshDisplay(force: true)
        updateWander()
        startTick()
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.poll() }
    }

    func buildPetWindow() {
        view = PetView(); view.owner = self
        view.wantsLayer = true   // materialize the backing layer + spriteLayer now
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

    // Hover cursor. A non-key accessory window never gets cursorUpdate/mouseMoved,
    // so we watch every system mouse move (global = events to other apps, local =
    // to us) and assert the open-hand cursor while the pointer is over the pet.
    // We only touch the cursor over the pet — elsewhere we leave it to whatever
    // app owns it, except for the one move that leaves the pet (restore arrow).
    func installCursorMonitor() {
        let handler: (NSEvent) -> Void = { [weak self] _ in self?.updateHoverCursor() }
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { handler($0) }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved])  { handler($0); return $0 }
    }

    func updateHoverCursor() {
        guard !dragging else { return }   // closed-hand is owned by the drag handlers
        if window.frame.contains(NSEvent.mouseLocation) {
            NSCursor.openHand.set()
            cursorOverPet = true
        } else if cursorOverPet {
            NSCursor.arrow.set()
            cursorOverPet = false
        }
    }

    func buildBubbleWindow() {
        bubbleView = BubbleView()
        bubbleView.onToggle = { [weak self] in self?.toggleExpanded() }
        // PetWindow (canBecomeKey == false) so clicking the chevron never steals
        // focus from whatever app the user is typing in.
        bubbleWindow = PetWindow(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                                 styleMask: .borderless, backing: .buffered, defer: false)
        bubbleWindow.isOpaque = false
        bubbleWindow.backgroundColor = .clear
        bubbleWindow.hasShadow = true
        bubbleWindow.level = .floating
        // hitTest in BubbleView makes everything except the chevron click-through.
        bubbleWindow.ignoresMouseEvents = false
        bubbleWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        bubbleWindow.contentView = bubbleView
        bubbleWindow.orderOut(nil)
    }

    // MARK: scale / position

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

    func applyScale() {
        let win = windowSizePx()
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = config.x ?? (screen.maxX - win.width - 24)
        let y = config.y ?? (screen.minY + 24)
        window.setFrame(NSRect(x: x, y: y, width: win.width, height: win.height), display: true)
        view.layoutSprite(rect: visualRectInWindow())
        repositionBubble()
    }

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

    func changeBubbleWidth(_ w: CGFloat) {
        config.bubbleWidth = max(60, min(400, w))
        config.save()
        if hasCard { applyCard() }
    }

    func toggleExpanded() {
        config.bubbleExpanded.toggle()
        config.save()
        if hasCard { applyCard() }
    }

    func changeBubbleOffset(x: CGFloat, y: CGFloat) {
        config.bubbleOffsetX = x
        config.bubbleOffsetY = y
        config.save()
        repositionBubble()
    }

    // MARK: interaction

    func beginDrag(grab: NSPoint) {
        sleepAfterTimer?.invalidate(); sleepAfterTimer = nil
        dragging = true; didMove = false; dragUnpinned = false
        px = window.frame.origin.x; py = window.frame.origin.y
        anchorX = px; anchorY = py
        grabDX = grab.x; grabDY = grab.y
        vx = 0; vy = 0; thrown = false; settlingDrop = false
        startTick()   // a sleeping pet has its deform tick paused — wake it so the grab/toss still stretches
        startPhysics(); refreshDisplay(); showTossFrame(); updateWander()
    }

    func dragTo(mouse: NSPoint) {
        anchorX = mouse.x - grabDX; anchorY = mouse.y - grabDY
        if abs(anchorX - px) > 2 || abs(anchorY - py) > 2 {
            didMove = true
            if !dragUnpinned {
                dragUnpinned = true
                showTossFrame()
            }
        }
    }

    func releaseDrag() {
        dragging = false
        // A real toss enters gravity flight. A gentle placement gets a short
        // local settle drop before it pins to the new spot.
        let launch: CGFloat = 150
        let launchVelocityScale: CGFloat = 0.45
        thrown = hypot(vx, vy) >= launch
        settlingDrop = false
        if thrown {
            vx *= launchVelocityScale; vy *= launchVelocityScale   // soften the throw — don't fling it across the screen
        } else if didMove {
            beginSettleDrop()
        } else {
            vx = 0; vy = 0
        }
    }

    func floorLimit() -> CGFloat? {
        guard let vis = NSScreen.main?.visibleFrame else { return nil }
        return vis.minY - visualRectInWindow().minY
    }

    func beginSettleDrop() {
        settlingDrop = true
        let drop = max(10, min(24, spriteSizePx().height * 0.18))
        let floor = floorLimit() ?? -CGFloat.greatestFiniteMagnitude
        settleTargetY = max(floor, py - drop)
        vx *= 0.15
        vy = min(vy, -120)
        if abs(py - settleTargetY) < 1 {
            settlingDrop = false
            vx = 0; vy = 0
        }
    }

    func startPhysics() {
        if physicsActive { return }
        physicsActive = true
        startTick()        // physics rides the deform display link; make sure it's running
        refreshDisplay()
    }

    func physicsStep(_ dt: CGFloat) {
        if dragging {
            let k: CGFloat = 620, damp: CGFloat = 26
            vx += (k * (anchorX - px) - damp * vx) * dt
            vy += (k * (anchorY - py) - damp * vy) * dt
        } else if thrown {
            // In flight after a toss: gravity pulls down (origin is bottom-left,
            // so "down" is -y) and a light air drag lets the horizontal throw
            // glide on instead of stopping dead the instant the mouse releases.
            let gravity: CGFloat = 3800, airDrag: CGFloat = 0.99
            vy -= gravity * dt
            vx *= airDrag
        } else if settlingDrop {
            let gravity: CGFloat = 1400
            vy -= gravity * dt
            vx *= 0.78
        } else {
            vx *= 0.82; vy *= 0.82
        }
        let cap: CGFloat = 2600
        vx = max(-cap, min(cap, vx)); vy = max(-cap, min(cap, vy))
        px += vx * dt; py += vy * dt

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
                if settlingDrop { settleTargetY = floorLimit }
            }
            onFloor = py <= floorLimit + 1
        }

        let settledDrop = settlingDrop && py <= settleTargetY
        if settledDrop {
            py = settleTargetY
            if vy < -30 { springV += SPRING_IMPACT * min(-vy, 260) * 0.006 }
            vx = 0; vy = 0
        }

        window.setFrameOrigin(NSPoint(x: px, y: py))
        // Face the direction of horizontal motion. Hysteresis avoids flicker.
        if vx < -40 { facingLeft = true }
        else if vx > 40 { facingLeft = false }
        showTossFrame()
        repositionBubble()

        // A toss keeps going until it has come to rest on the floor; a gentle
        // drop (not thrown) settles the moment it's nearly still.
        if settledDrop || (!dragging && abs(vx) < 8 && abs(vy) < 25 && (!thrown || onFloor)) {
            stopPhysics()
        }
    }

    func stopPhysics() {
        physicsActive = false
        vx = 0; vy = 0; thrown = false; settlingDrop = false; dragUnpinned = false
        if didMove {
            config.x = window.frame.origin.x; config.y = window.frame.origin.y
            config.save()
        }
        if asleep { stopTick() }
        refreshDisplay(); updateWander()
    }

    func tossFrameColumn() -> Int {
        if dragging {
            if !dragUnpinned { return 0 }
            let movingUpDiagonal = vy > 80 && abs(vx) > 50
            return movingUpDiagonal ? 4 : 2
        }
        if vy < -120 { return 1 }
        return 2
    }

    func showTossFrame() {
        // Mouse-down starts pinned/crouched; actual movement makes it unpinned
        // and airborne. Use a jump pose only for deliberate upward diagonal movement.
        view.show(sprite.frame(row: JUMP_ROW, col: tossFrameColumn(), flipped: facingLeft))
    }

    // MARK: polling (single event.json — merges state + bubble)

    func poll() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: EVENT_PATH),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
              mtime != lastEventMtime else { return }
        lastEventMtime = mtime
        guard let data = FileManager.default.contents(atPath: EVENT_PATH),
              let obj  = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        // animation state. A new event always cancels a pending delayed-sleep:
        // whoever wrote this file is the freshest word on what the pet is doing.
        sleepAfterTimer?.invalidate(); sleepAfterTimer = nil
        let sleep = (obj["sleep"] as? Bool) ?? false
        if sleep != asleep {
            asleep = sleep
            window.animator().alphaValue = sleep ? 0.45 : 1.0   // dim = "asleep"
            updateWander()
            if sleep { stopTick() } else { startTick() }        // pause deformation while asleep
        }
        if let s = obj["state"] as? String { setAgentState(s) }

        // sleep_after: show this card now, then drift to sleep after N seconds —
        // lets a finished session linger on "Готово" before the pet dozes off.
        let sleepAfter = (obj["sleep_after"] as? Double) ?? 0
        if sleepAfter > 0 && !asleep {
            sleepAfterTimer = Timer.scheduledTimer(withTimeInterval: sleepAfter, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.asleep = true
                self.window.animator().alphaValue = 0.45
                self.hasCard = false
                self.bubbleWindow.orderOut(nil); self.stopSpinner()
                self.updateWander()
                self.stopTick()
            }
        }

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

    // Build the card from the last raw values and show it. The status (current
    // activity) is the prominent line; the topic (first message) is a small soft
    // caption shown above it only when expanded. Doneness is shown by the icon.
    func applyCard() {
        let icon = iconFor(lastColorName)
        bubbleView.caption      = lastTitle
        bubbleView.status       = lastStatus
        bubbleView.detail       = lastDetail
        bubbleView.detailIsCode = lastDetailCode
        bubbleView.expanded     = config.bubbleExpanded
        bubbleView.icon         = icon
        bubbleView.accent       = statusColor(lastColorName)
        bubbleView.statusFont  = vintageFont(config.bubbleFont, config.bubbleFontSize + 1, bold: true)
        bubbleView.captionFont = vintageFont(config.bubbleFont, max(8, config.bubbleFontSize - 3), bold: false)
        bubbleView.detailFont  = vintageFont(config.bubbleFont, config.bubbleFontSize, bold: false)
        bubbleView.maxTextWidth = config.bubbleWidth
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

    // MARK: display-linked tick (refresh-rate while awake)

    // One callback per displayed frame. Drives physics (only while tossing) and the
    // always-on procedural deform, using the real time between frames so motion runs
    // at correct speed regardless of the actual frame rate.
    @objc func frameTick(_ link: CADisplayLink) {
        let now = link.timestamp
        var dt = lastFrameT > 0 ? CGFloat(now - lastFrameT) : CGFloat(link.targetTimestamp - link.timestamp)
        lastFrameT = now
        dt = max(0, min(dt, MAX_DT))
        if physicsActive { physicsStep(dt) }       // may stopPhysics() / stopTick() mid-frame
        if displayLink != nil { proceduralStep(dt) }
    }

    func startTick() {
        if displayLink != nil { return }
        lastFrameT = 0   // first frame after (re)start uses a nominal dt, not a stale gap
        let link = view.displayLink(target: self, selector: #selector(frameTick(_:)))
        link.add(to: .main, forMode: .common)   // .common so it keeps firing during a drag
        displayLink = link
    }

    func stopTick() {
        displayLink?.invalidate(); displayLink = nil
        view.setDeform(sx: 1, sy: 1, rot: 0)   // rest at identity so a sleeping pet isn't mid-squash
    }

    func proceduralStep(_ dt: CGFloat) {
        // Impact spring (always integrating; rings down to zero on its own).
        springV += (-SPRING_K * springS - SPRING_DAMP * springV) * dt
        springS += springV * dt
        springS = max(-0.16, min(0.16, springS))
        breathPhase += dt

        var sx: CGFloat = 1, sy: CGFloat = 1

        // Breathing: idle state only, when settled.
        let settled = !tossing && abs(vx) < 25 && abs(vy) < 25
        if playing == "idle" && settled {
            let b = sin(breathPhase * BREATH_SPEED) * BREATH_AMP
            sy *= 1 + b; sx *= 1 - b * 0.6
        }

        // Velocity stretch: the whole toss (held + in flight). The frame is held stable,
        // so this continuous stretch is what conveys vertical motion.
        if tossing {
            let st = min(abs(vy) / SS_REF, 1) * SS_FORCE
            sy *= 1 + st; sx *= 1 - st * 0.5
        }

        // Impact squash.
        sy *= 1 - springS; sx *= 1 + springS * 0.6
        sx = max(DEFORM_MIN_SX, min(DEFORM_MAX_SX, sx))
        sy = max(DEFORM_MIN_SY, min(DEFORM_MAX_SY, sy))

        // Lean into horizontal velocity, eased — during the toss, upright at rest.
        let target = tossing ? max(-TILT_MAX, min(TILT_MAX, vx * (TILT_MAX / TILT_REF))) : 0
        tiltDeg += (target - tiltDeg) * min(1, dt * 12)

        view.setDeform(sx: sx, sy: sy, rot: tiltDeg * .pi / 180)
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
        var x = pet.minX - 2 - b.width + 1 + config.bubbleOffsetX
        var y = pet.midY - 2 + config.bubbleOffsetY
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
