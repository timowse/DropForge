import AppKit
import UniformTypeIdentifiers
import DropForgeCore

/// What a drag carries, as far as it can be known before the drop.
public enum DragContents {
    case files([URL])
    /// File promises (Photos, Mail, browsers): types are known, files arrive only after the drop.
    case promises([NSFilePromiseReceiver])
    case none

    @MainActor
    public static func read(_ pasteboard: NSPasteboard) -> DragContents {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return .files(urls)
        }
        if let promises = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver],
           !promises.isEmpty {
            return .promises(promises)
        }
        return .none
    }

    /// Selection for choosing options. Promised files get placeholder URLs carrying the promised type.
    public var provisionalSelection: Selection? {
        switch self {
        case .files(let urls): return Selection(urls: urls)
        case .promises(let receivers):
            let items: [DroppedItem] = receivers.enumerated().flatMap { i, r in
                r.fileTypes.map { type -> DroppedItem in
                    let ext = UTType(type)?.preferredFilenameExtension ?? "dat"
                    let url = URL(fileURLWithPath: "/promised/item-\(i).\(ext)")
                    let format = FileFormat.detect(url)
                    return DroppedItem(url: url, format: format, kind: format?.kind ?? .other, byteSize: 0, isDirectory: false)
                }
            }
            return items.isEmpty ? nil : Selection(items: items)
        case .none: return nil
        }
    }
}

final class SegmentAccessibilityElement: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return onPress != nil
    }
}

/// Draws the wheel and handles mouse, keyboard and drag-and-drop.
@MainActor
public final class WheelView: NSView {
    public let model: WheelModel
    public var scale: CGFloat = 1 { didSet { needsDisplay = true } }
    /// Called with the drop's contents just before a drop commits (so promises can be received).
    public var onDropContents: ((DragContents) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var cachedElements: [NSAccessibilityElement] = []
    private var pressedIndex: Int?

    public init(model: WheelModel) {
        self.model = model
        super.init(frame: NSRect(origin: .zero, size: WheelView.preferredSize(for: model.layout, scale: 1)))
        registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    public override var isFlipped: Bool { false }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public static func preferredSize(for layout: WheelLayout, scale: CGFloat) -> NSSize {
        let r = CGFloat(max(layout.outerRadius, Double(Tokens.Wheel.hubRadius + Tokens.Wheel.ringGap + Tokens.Wheel.ringWidth))) * scale
        let side = 2 * r + 2 * Tokens.Wheel.margin
        return NSSize(width: max(side, 380 * scale), height: side + (Tokens.Wheel.headerHeight + Tokens.Wheel.footerHeight) * scale)
    }

    var wheelCenter: CGPoint {
        let footer = Tokens.Wheel.footerHeight * scale
        return CGPoint(x: bounds.midX, y: footer + (bounds.height - Tokens.Wheel.headerHeight * scale - footer) / 2)
    }

    var footerRect: CGRect {
        let h = Tokens.Wheel.footerHeight * scale - 6
        let w = min(bounds.width - 16, 360 * scale)
        return CGRect(x: bounds.midX - w / 2, y: 2, width: w, height: h)
    }

    /// Output preview for the highlighted segment, or how to operate the wheel.
    var footerText: String {
        if let preview = model.hubPreview { return preview }
        switch model.mode {
        case .drag: return model.segments.isEmpty ? "Tap another key to switch wheels" : "Drop on a segment · centre or outside cancels"
        case .keyboard: return "←→ choose · ↩ apply · ⇥ switch · ⎋ cancel"
        }
    }

    var discRadius: CGFloat {
        CGFloat(max(model.layout.outerRadius, Double(Tokens.Wheel.hubRadius + Tokens.Wheel.ringGap + Tokens.Wheel.ringWidth))) * scale + 6
    }

    /// Converts a view point into unscaled wheel coordinates.
    func wheelPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (p.x - wheelCenter.x) / scale, y: (p.y - wheelCenter.y) / scale)
    }

    public func segmentIndex(at viewPoint: CGPoint) -> Int? {
        model.layout.hitTest(wheelPoint(viewPoint))
    }

    func isOutsideDisc(_ viewPoint: CGPoint) -> Bool {
        let p = CGPoint(x: viewPoint.x - wheelCenter.x, y: viewPoint.y - wheelCenter.y)
        return hypot(p.x, p.y) > discRadius && !headerRect.contains(viewPoint) && !footerRect.contains(viewPoint)
    }

    var headerRect: CGRect {
        let h = Tokens.Wheel.headerHeight * scale - 6
        let w = min(bounds.width - 16, 300 * scale)
        return CGRect(x: bounds.midX - w / 2, y: bounds.height - h - 2, width: w, height: h)
    }

    func pillRects() -> [(OperationCategory, CGRect)] {
        let r = headerRect.insetBy(dx: 3, dy: 3)
        let w = r.width / 3
        return OperationCategory.allCases.enumerated().map { i, c in
            (c, CGRect(x: r.minX + CGFloat(i) * w, y: r.minY, width: w, height: r.height).insetBy(dx: 2, dy: 0))
        }
    }

    // MARK: Drawing

    func tone(_ c: OperationCategory) -> NSColor {
        switch c {
        case .convert: Tokens.Palette.accent
        case .tools: Tokens.Palette.secondary
        case .actions: Tokens.Palette.tertiary
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        let hc = Tokens.Motion.highContrast
        let solid = Tokens.Motion.reduceTransparency || hc
        let center = wheelCenter
        let accent = tone(model.category)

        // Disc.
        let disc = NSBezierPath(ovalIn: CGRect(x: center.x - discRadius, y: center.y - discRadius, width: 2 * discRadius, height: 2 * discRadius))
        NSColor.windowBackgroundColor.withAlphaComponent(solid ? 1 : 0.95).setFill()
        disc.fill()
        NSColor.labelColor.withAlphaComponent(hc ? Tokens.Wheel.strokeAlphaHighContrast : Tokens.Wheel.strokeAlpha).setStroke()
        disc.lineWidth = hc ? 2 : 1
        disc.stroke()

        drawHeader(highContrast: hc, solid: solid)

        // Segments.
        for seg in model.layout.segments {
            let path = sectorPath(seg, center: center)
            let isHot = seg.index == model.highlighted
            if isHot {
                accent.setFill()
                NSColor.labelColor.withAlphaComponent(0.5).setStroke()
            } else {
                NSColor.labelColor.withAlphaComponent(hc ? Tokens.Wheel.segmentFillAlphaHighContrast : Tokens.Wheel.segmentFillAlpha).setFill()
            }
            path.fill()
            if hc || isHot {
                let stroke = hc ? NSColor.labelColor : accent.shadow(withLevel: 0.35) ?? accent
                (isHot || hc ? stroke : NSColor.labelColor.withAlphaComponent(Tokens.Wheel.strokeAlphaHighContrast)).setStroke()
                path.lineWidth = isHot ? (hc ? 3 : 1.5) : 1.5
                path.stroke()
            }
            let segment = model.segments[seg.index]
            let p = CGPoint(x: center.x + seg.labelPoint.x * scale, y: center.y + seg.labelPoint.y * scale)
            let fg = isHot ? Tokens.Palette.onAccent : NSColor.labelColor
            drawSymbol(segment.symbolName, at: CGPoint(x: p.x, y: p.y + 9 * scale), color: isHot ? fg : accent)
            let chord = min(CGFloat(seg.outerRadius - seg.innerRadius) * 1.25, CGFloat(seg.midRadius) * CGFloat(seg.endAngle - seg.startAngle)) * scale
            drawText(segment.title, in: CGRect(x: p.x - chord / 2, y: p.y - 18 * scale, width: chord, height: 15 * scale),
                     size: Tokens.Wheel.labelPointSize * scale, weight: .semibold, color: fg)
        }

        // Hub.
        let hubR = CGFloat(model.layout.hubRadius) * scale
        let hub = NSBezierPath(ovalIn: CGRect(x: center.x - hubR, y: center.y - hubR, width: 2 * hubR, height: 2 * hubR))
        NSColor.controlBackgroundColor.setFill()
        hub.fill()
        accent.withAlphaComponent(hc ? 1 : 0.55).setStroke()
        hub.lineWidth = hc ? 2.5 : 1.5
        hub.stroke()
        let kindSymbol = model.selection?.uniformKind?.symbolName ?? (model.selection == nil ? "hourglass" : "square.stack")
        drawSymbol(kindSymbol, at: CGPoint(x: center.x, y: center.y + hubR * 0.52), color: accent, size: 15 * scale)
        let w = hubR * 1.75
        drawText(model.hubTitle, in: CGRect(x: center.x - w / 2, y: center.y + 2 * scale, width: w, height: 16 * scale),
                 size: Tokens.Wheel.hubTitlePointSize * scale, weight: .semibold, color: .labelColor)
        drawText(model.hubSubtitle, in: CGRect(x: center.x - w / 2, y: center.y - 26 * scale, width: w, height: 28 * scale),
                 size: Tokens.Wheel.hubDetailPointSize * scale, weight: .regular, color: .secondaryLabelColor, lines: 2)
        drawFooter(accent: accent, highContrast: hc, solid: solid)
        window?.invalidateShadow()
    }

    func drawFooter(accent: NSColor, highContrast hc: Bool, solid: Bool) {
        let r = footerRect
        let capsule = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor.windowBackgroundColor.withAlphaComponent(solid ? 1 : 0.95).setFill()
        capsule.fill()
        NSColor.labelColor.withAlphaComponent(hc ? Tokens.Wheel.strokeAlphaHighContrast : Tokens.Wheel.strokeAlpha).setStroke()
        capsule.stroke()
        let isPreview = model.hubPreview != nil
        drawText(footerText, in: r.insetBy(dx: 12, dy: (r.height - 14 * scale) / 2), size: 11 * scale,
                 weight: isPreview ? .semibold : .regular, color: isPreview ? accent : .secondaryLabelColor)
    }

    func drawHeader(highContrast hc: Bool, solid: Bool) {
        let header = NSBezierPath(roundedRect: headerRect, xRadius: headerRect.height / 2, yRadius: headerRect.height / 2)
        NSColor.windowBackgroundColor.withAlphaComponent(solid ? 1 : 0.95).setFill()
        header.fill()
        NSColor.labelColor.withAlphaComponent(hc ? Tokens.Wheel.strokeAlphaHighContrast : Tokens.Wheel.strokeAlpha).setStroke()
        header.stroke()
        let hints = Dictionary(uniqueKeysWithValues: model.categoryHints)
        for (c, rect) in pillRects() {
            let active = c == model.category
            if active {
                let pill = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
                tone(c).setFill()
                pill.fill()
            }
            drawText(hints[c] ?? c.title, in: rect.insetBy(dx: 4, dy: (rect.height - 14 * scale) / 2),
                     size: 11 * scale, weight: active ? .bold : .medium,
                     color: active ? Tokens.Palette.onAccent : .secondaryLabelColor)
        }
    }

    func sectorPath(_ s: WheelSegmentGeometry, center: CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        let r0 = CGFloat(s.innerRadius) * scale, r1 = CGFloat(s.outerRadius) * scale
        let a0 = CGFloat(s.startAngle) * 180 / .pi, a1 = CGFloat(s.endAngle) * 180 / .pi
        path.appendArc(withCenter: center, radius: r1, startAngle: a0, endAngle: a1, clockwise: false)
        path.appendArc(withCenter: center, radius: r0, startAngle: a1, endAngle: a0, clockwise: true)
        path.close()
        return path
    }

    func drawSymbol(_ name: String, at p: CGPoint, color: NSColor, size: CGFloat? = nil) {
        let pt = size ?? Tokens.Wheel.iconPointSize * scale
        let config = NSImage.SymbolConfiguration(pointSize: pt, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
            ?? NSImage(systemSymbolName: "circle", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
        let s = image.size
        image.draw(in: CGRect(x: p.x - s.width / 2, y: p.y - s.height / 2, width: s.width, height: s.height))
    }

    func drawText(_ text: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight, color: NSColor, lines: Int = 1) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = lines == 1 ? .byTruncatingMiddle : .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                    .foregroundColor: color, .paragraphStyle: style]
        let s = NSAttributedString(string: text, attributes: attrs)
        let options: NSString.DrawingOptions = lines == 1 ? [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
                                                          : [.usesLineFragmentOrigin, .truncatesLastVisibleLine]
        s.draw(with: rect, options: options)
    }

    // MARK: Mouse (keyboard mode and clicks)

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) {
        model.hover(segmentIndex(at: convert(event.locationInWindow, from: nil)))
    }

    public override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let (c, _) = pillRects().first(where: { $0.1.contains(p) }) {
            model.switchTo(c)
            return
        }
        if isOutsideDisc(p) { model.cancel(); return }
        pressedIndex = segmentIndex(at: p)
    }

    public override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = segmentIndex(at: p), i == pressedIndex { model.commit(index: i) }
        pressedIndex = nil
    }

    // MARK: Keyboard

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: model.move(.left)
        case 124: model.move(.right)
        case 125: model.move(.down)
        case 126: model.move(.up)
        case 36, 76, 49: model.commit()
        case 53: model.cancel()
        case 48: model.nextCategory(reverse: event.modifierFlags.contains(.shift))
        default: super.keyDown(with: event)
        }
    }

    public override func cancelOperation(_ sender: Any?) { model.cancel() }

    private var lastFlags: NSEvent.ModifierFlags = []
    public override func flagsChanged(with event: NSEvent) {
        let now = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let fresh = now.subtracting(lastFlags)
        lastFlags = now
        for m in ModifierMapping.modifiers(from: fresh) {
            if let c = model.category(forModifier: m) { model.switchTo(c); break }
        }
    }

    // MARK: Drag destination

    func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        let p = convert(sender.draggingLocation, from: nil)
        if model.selection == nil, let sel = DragContents.read(sender.draggingPasteboard).provisionalSelection {
            model.setSelection(sel)
        }
        let i = segmentIndex(at: p)
        model.hover(i)
        return i == nil ? [] : .copy
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
    public override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { operation(for: sender) }
    public override func draggingExited(_ sender: NSDraggingInfo?) { model.hover(nil) }
    public override func wantsPeriodicDraggingUpdates() -> Bool { false }

    public override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        segmentIndex(at: convert(sender.draggingLocation, from: nil)) != nil
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let i = segmentIndex(at: convert(sender.draggingLocation, from: nil)) else { return false }
        let contents = DragContents.read(sender.draggingPasteboard)
        if case .files(let urls) = contents { model.setSelection(Selection(urls: urls)) }
        onDropContents?(contents)
        return model.commit(index: i)
    }

    // MARK: Accessibility

    public override func accessibilityLabel() -> String? {
        "DropForge \(model.category.title) wheel. \(model.hubTitle). \(model.segments.count) options."
    }

    public override func accessibilityChildren() -> [Any]? {
        rebuildAccessibility()
        return cachedElements
    }

    func rebuildAccessibility() {
        var elements: [NSAccessibilityElement] = []
        for (c, rect) in pillRects() {
            let e = SegmentAccessibilityElement()
            e.setAccessibilityParent(self)
            e.setAccessibilityRole(.radioButton)
            e.setAccessibilityLabel("\(c.title) wheel")
            e.setAccessibilityValue(c == model.category ? 1 : 0)
            e.setAccessibilityFrameInParentSpace(rect)
            e.onPress = { [weak self] in self?.model.switchTo(c) }
            elements.append(e)
        }
        let center = wheelCenter
        for seg in model.layout.segments {
            let segment = model.segments[seg.index]
            let e = SegmentAccessibilityElement()
            e.setAccessibilityParent(self)
            e.setAccessibilityRole(.button)
            e.setAccessibilityLabel(segment.accessibilityLabel)
            e.setAccessibilityHelp(model.selection.map { "Applies to \($0.summary)" })
            e.setAccessibilitySelected(seg.index == model.highlighted)
            let p = CGPoint(x: center.x + seg.labelPoint.x * scale, y: center.y + seg.labelPoint.y * scale)
            e.setAccessibilityFrameInParentSpace(CGRect(x: p.x - 30 * scale, y: p.y - 24 * scale, width: 60 * scale, height: 48 * scale))
            let index = seg.index
            e.onPress = { [weak self] in self?.model.commit(index: index) }
            elements.append(e)
        }
        cachedElements = elements
    }
}

enum ModifierMapping {
    static func modifiers(from flags: NSEvent.ModifierFlags) -> [Modifier] {
        var out: [Modifier] = []
        if flags.contains(.shift) { out.append(.shift) }
        if flags.contains(.command) { out.append(.command) }
        if flags.contains(.control) { out.append(.control) }
        if flags.contains(.option) { out.append(.option) }
        return out
    }

    static func set(from flags: NSEvent.ModifierFlags) -> Set<Modifier> { Set(modifiers(from: flags)) }
}
