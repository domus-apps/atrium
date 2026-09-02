import AppKit

/* The layered switcher overlay: a borderless, non-activating panel so the
   frontmost app keeps keyboard focus while it is up — cycling is driven by
   global hotkeys, not by this window becoming key.

   The Liquid Glass treatment (clear material tuning, specular rim,
   keep-attached trick) follows Transom's BrightnessHUD — see
   BrightnessHUD.swift there for the calibration story. The material values
   are kept identical so the apps match; the rim is re-derived for a large,
   variable-size panel (see RimView). */
final class SwitcherPanel: NSPanel {
    private static let cornerRadius: CGFloat = 48
    /* "Hidden" alpha: at exactly 0 the window server detaches the window
       and the next reveal re-commits stock glass material — a hair above
       zero keeps it attached. As small as possible: this panel is large,
       and on dark backdrops even 1% of a bright glass face reads as a
       ghost. The content is also stripped while hidden (see dismiss), so
       what remains at this alpha is bare glass. */
    private static let hiddenAlpha: CGFloat = 0.002

    var onItemClick: ((Int) -> Void)?
    var onItemHover: ((Int) -> Void)?
    /// Whether the switcher is currently presented. Not `isVisible`: the
    /// panel stays ordered in at 1% alpha forever (see hiddenAlpha).
    private(set) var isPresented = false

    private let glass = NSGlassEffectView()
    /* The cards live in a SIBLING above the glass, not in glass.contentView:
       content inside the glass feeds the material pipeline, so a dark
       selection scrim would reflect into the glass and darken the whole
       face. As a plain overlay the cards draw flat on top while the glass
       refracts only the desktop behind the panel. (It also means the glass
       internals — including the tuned backdrop layer — are never torn down
       by content changes.) */
    private let gridHost = NSView()
    private var rim: RimView?
    private var itemViews: [SwitcherItemView] = []
    private var tuneEpsilonFlip = false
    /* Stamps each show; a delayed reveal from a superseded show must not
       fire early into the next one's stock-material window. */
    private var revealGeneration = 0

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        /* Above regular windows and the menu bar; joins every Space and
           full-screen app so the switcher appears wherever the user is. */
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        backgroundColor = .clear
        isOpaque = false
        /* No system shadow: it would paint a 1px dark contour on the window
           boundary, right over the rim highlight. */
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        /* Dormant panels must never eat clicks; flipped on for each show. */
        ignoresMouseEvents = true
        /* Hover selection reacts to the slightest cursor motion, which
           needs moved events, not just enter/exit. */
        acceptsMouseMovedEvents = true
        /* Follows the system appearance: the material tuning switches
           between a bright and a dark transfer (see tuneGlassMaterial),
           and the content uses semantic colors that flip with it. */

        glass.style = .clear
        glass.cornerRadius = Self.cornerRadius
        let container = NSView()
        container.wantsLayer = true
        container.addSubview(glass)
        container.addSubview(gridHost)
        contentView = container

        /* Created invisible at launch, ordered in once, and never ordered
           out — hiding is alpha-only. Every time the glass view (re)attaches
           to the window server it re-commits the stock material, clobbering
           the tuning for about half a second; keeping the window attached
           means even the very first Option+Tab shows the final glass. */
        alphaValue = Self.hiddenAlpha
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let screen = NSScreen.main {
                let frame = screen.frame
                setFrame(
                    NSRect(x: frame.midX - 100, y: frame.midY - 70, width: 200, height: 140),
                    display: false)
            }
            orderFrontRegardless()
            for delay in [0.7, 1.4] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.tuneGlassMaterial()
                }
            }
        }
    }

    /* Non-activating panels can still become key by click; refusing keeps
       the previous app focused even when an item is clicked. */
    override var canBecomeKey: Bool { false }

    func show(windows: [SwitcherWindow], selectedIndex: Int, on screen: NSScreen) {
        let resized = layout(windows: windows, on: screen)
        select(selectedIndex)
        isPresented = true
        ignoresMouseEvents = false
        revealGeneration += 1
        let generation = revealGeneration
        if resized {
            /* A resize re-commits the stock frosted material a frame or two
               from now (see layout) — revealing immediately would flash it,
               which is exactly what happened when alternating Option+Tab and
               Option+` (different list, different size). Stay at the hidden
               alpha until the re-commit has come and gone under the tight
               re-tune cadence, then reveal fully tuned. Three frames of
               latency is imperceptible; the frosted flash was not. */
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self, isPresented, generation == revealGeneration else { return }
                reveal()
            }
        } else {
            reveal()
        }
        orderFrontRegardless()
    }

    private func reveal() {
        /* Zero-duration animator write: replaces any in-flight fade where a
           plain alphaValue assignment would race it. */
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().alphaValue = 1
        }
    }

    /// Sizes and populates the dormant panel without presenting it. Called
    /// once shortly after launch: the first real show then (usually) needs
    /// no resize, and it's the resize that momentarily flashes stock
    /// frosted material before the re-tune lands. Only the SIZE needs to
    /// persist — the content is stripped again right away (see dismiss).
    func preLayout(windows: [SwitcherWindow], on screen: NSScreen) {
        guard !isPresented else { return }
        layout(windows: windows, on: screen)
        clearContent()
    }

    /// Returns whether the panel's size changed — the caller delays the
    /// reveal in that case (a resize momentarily reverts the glass to stock
    /// material; see show).
    @discardableResult
    private func layout(windows: [SwitcherWindow], on screen: NSScreen) -> Bool {
        itemViews = windows.enumerated().map { index, window in
            let view = SwitcherItemView(window: window)
            view.onClick = { [weak self] in self?.onItemClick?(index) }
            view.onHover = { [weak self] in self?.onItemHover?(index) }
            return view
        }

        gridHost.subviews.forEach { $0.removeFromSuperview() }
        let size = layOutItems(in: gridHost, limitedBy: screen.visibleFrame.width * 0.8)
        let resized = size != frame.size

        setFrame(
            NSRect(
                x: screen.visibleFrame.midX - size.width / 2,
                y: screen.visibleFrame.midY - size.height / 2,
                width: size.width,
                height: size.height
            ),
            display: false
        )
        if let container = contentView {
            gridHost.frame = container.bounds
        }
        if let container = contentView, resized || rim == nil {
            glass.frame = container.bounds
            /* The rim's layers are built for a fixed size — rebuild when the
               panel's size actually changed. */
            rim?.removeFromSuperview()
            /* A sibling ABOVE the glass view: the glass draws its own edge
               treatment over its contentView, so a line inside the content
               could never sit on the boundary. */
            let newRim = RimView(frame: container.bounds, cornerRadius: Self.cornerRadius)
            container.addSubview(newRim)
            rim = newRim
        }

        /* A resize makes the glass re-commit its stock material (the same
           way re-attaching does), so the tuning must be re-applied — on a
           tight per-frame cadence at first, since the re-commit lands a
           frame or two after the resize and anything slower shows as a
           frosted flash (the reveal is also held back past this window;
           see show). */
        tuneGlassMaterial()
        if resized {
            for delay in [0.016, 0.033, 0.05, 0.15, 0.3, 0.7] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.tuneGlassMaterial()
                }
            }
        }
        return resized
    }

    /* Alpha-only, never to zero, never ordered out: both would reset the
       tuned material (see init). The cards and rim are stripped so nothing
       bright lingers in the near-invisible dormant window — on dark
       backdrops even a fraction of a percent of white content shows as an
       afterimage, while bare glass does not. */
    func dismiss() {
        isPresented = false
        revealGeneration += 1
        ignoresMouseEvents = true
        clearContent()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().alphaValue = Self.hiddenAlpha
        }
    }

    private func clearContent() {
        gridHost.subviews.forEach { $0.removeFromSuperview() }
        itemViews = []
        rim?.removeFromSuperview()
        rim = nil
    }

    func select(_ index: Int) {
        for (viewIndex, view) in itemViews.enumerated() {
            view.isSelected = viewIndex == index
        }
    }

    func setPreview(_ image: NSImage, at index: Int) {
        guard itemViews.indices.contains(index) else { return }
        itemViews[index].showPreview(image)
    }

    /// The item one visual row above (`rowStep` -1) or below (+1) `index` —
    /// the one whose horizontal center is nearest. Rows are centered, so a
    /// partial last row's items sit BETWEEN the columns above them; index
    /// arithmetic (± items-per-row) would land visibly sideways, while the
    /// geometric nearest-center match moves where the eye expects.
    func itemIndex(rowStep step: Int, from index: Int) -> Int? {
        guard itemViews.indices.contains(index) else { return nil }
        let current = itemViews[index].frame
        /* Visual rows, top to bottom (AppKit's y grows upward). */
        let rowYs = Set(itemViews.map(\.frame.midY)).sorted(by: >)
        guard
            let currentRow = rowYs.firstIndex(where: { abs($0 - current.midY) < 1 }),
            rowYs.indices.contains(currentRow + step)
        else { return nil }
        let targetY = rowYs[currentRow + step]
        return itemViews.enumerated()
            .filter { abs($0.element.frame.midY - targetY) < 1 }
            .min {
                abs($0.element.frame.midX - current.midX)
                    < abs($1.element.frame.midX - current.midX)
            }?
            .offset
    }

    /* Rows wrap at the width limit and each row is centered, so a partial
       last row doesn't hang off the left edge. Returns the panel size. */
    private func layOutItems(in container: NSView, limitedBy maxWidth: CGFloat) -> CGSize {
        let item = SwitcherItemView.size
        let spacing: CGFloat = 4
        /* Generous enough that the corner cards clear the large corner
           arcs instead of poking into them. */
        let padding: CGFloat = 28
        let count = itemViews.count

        let fitting = Int((maxWidth - 2 * padding + spacing) / (item.width + spacing))
        let perRow = max(1, min(count, fitting))
        let rows = (count + perRow - 1) / perRow

        let width = CGFloat(perRow) * (item.width + spacing) - spacing + 2 * padding
        let height = CGFloat(rows) * (item.height + spacing) - spacing + 2 * padding

        for (index, view) in itemViews.enumerated() {
            let row = index / perRow
            let column = index % perRow
            let itemsInRow = min(perRow, count - row * perRow)
            let rowWidth = CGFloat(itemsInRow) * (item.width + spacing) - spacing
            view.frame = NSRect(
                x: (width - rowWidth) / 2 + CGFloat(column) * (item.width + spacing),
                y: height - padding - CGFloat(row + 1) * item.height - CGFloat(row) * spacing,
                width: item.width,
                height: item.height
            )
            container.addSubview(view)
        }
        return CGSize(width: width, height: height)
    }

    /* Tunes the glass material — Transom's tuning as the baseline, with the
       face transfer pushed brighter (see the values below) so the big panel
       reads more transparent. The material is a private "glassBackground"
       filter on a backdrop layer inside NSGlassEffectView; its face color
       matrix maps backdrop luminance as out = black + (white − black) · in.
       Values must be set through the layer's filter key path — mutating the
       filter object directly never reaches the render server.

       The backdrop layer only exists a runloop turn or two after the panel
       first comes on screen, so retry briefly before falling back. If the
       private structure ever changes, the fallback is a black tint that
       approximates the same transfer. */
    private func tuneGlassMaterial(attempt: Int = 0) {
        func findBackdropLayer(_ layer: CALayer) -> CALayer? {
            if String(describing: type(of: layer)) == "CABackdropLayer" { return layer }
            for sublayer in layer.sublayers ?? [] {
                if let found = findBackdropLayer(sublayer) { return found }
            }
            return nil
        }
        guard
            let layer = glass.layer,
            let backdrop = findBackdropLayer(layer),
            (backdrop.filters?.first as? NSObject)?.value(forKey: "name") as? String
                == "glassBackground"
        else {
            if attempt < 5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.tuneGlassMaterial(attempt: attempt + 1)
                }
            } else {
                glass.tintColor = .black.withAlphaComponent(0.05)
            }
            return
        }
        glass.tintColor = nil
        /* An imperceptible epsilon toggled per application: Core Animation
           only commits a filter value when the model actually changes, and
           the view's stock re-commit resets the render server WITHOUT
           touching the model — re-setting an identical value would be
           silently dropped and the stock material would stay visible. */
        tuneEpsilonFlip.toggle()
        let epsilon = tuneEpsilonFlip ? 1e-6 : 0.0
        /* Two transfers, picked by the effective appearance. Light: brighter
           than Transom's tuning (white 0.90 / black 0.06 / cap 0.86) — the
           transfer is pushed closer to identity so the backdrop passes
           through lighter and the glass reads clearer. Dark: the SAME clear
           glass, just moderately dimmed — only the brightness of the
           transfer drops, nothing else about the material changes. */
        let isDark =
            effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        /* Light mode's `black` is deliberately lifted well off zero, plus a
           touch of white fill below: a dark window behind the panel would
           otherwise pass through nearly black and swallow the black labels. */
        let white = isDark ? 0.76 : 0.98
        let black = isDark ? 0.07 : 0.18
        let maxLuma = isDark ? 0.72 : 0.95
        let fillAlpha = isDark ? 0.0 : 0.10
        backdrop.setValue(
            white + epsilon, forKeyPath: "filters.glassBackground.inputFaceColorMatrixWhite")
        backdrop.setValue(
            black + epsilon, forKeyPath: "filters.glassBackground.inputFaceColorMatrixBlack")
        /* Legibility without smoking the whole face: cap the luminance the
           backdrop can reach through the glass. */
        backdrop.setValue(
            maxLuma + epsilon,
            forKeyPath: "filters.glassBackground.inputFaceColorMatrixMaxLuma")
        backdrop.setValue(
            maxLuma + epsilon,
            forKeyPath: "filters.glassBackground.inputFaceColorMatrixMaxLumaSDR")
        backdrop.setValue(
            NSColor.white.withAlphaComponent(fillAlpha).cgColor,
            forKeyPath: "filters.glassBackground.inputFaceColorMatrixFillColor")
        backdrop.setValue(
            0.25 + epsilon, forKeyPath: "filters.glassBackground.inputBlurRadius")
        backdrop.setValue(
            -60.0 + epsilon,
            forKeyPath: "filters.glassBackground.inputInnerRefractionAmount")
        backdrop.setValue(
            26.0 + epsilon,
            forKeyPath: "filters.glassBackground.inputInnerRefractionHeight")
        backdrop.setValue(
            0.65 + epsilon,
            forKeyPath: "filters.glassBackground.inputKeyFillHighlightAmount")
    }

    /* The specular rim on the panel's border, structured like Transom's but
       re-derived for a large, variable-size panel. Transom's gradients place
       their fades at FRACTIONS of the height — calibrated on a 66pt pill,
       where the bright top line dies within ~25pt. Scaled to a panel several
       hundred points tall, the same fractions smear the highlight over a
       hundred-plus points and it stops reading as an edge reflection. Here
       every band is fixed in points (relative to the corner radius, like the
       native glass edge), so the highlight hugs the rim at any panel size:
       a crisp additive line brightest along the top, wrapping the corner
       arcs, decaying into a faint dark hairline down the sides, with only a
       tight glow bleeding inward. */
    private final class RimView: NSView {
        init(frame: NSRect, cornerRadius: CGFloat) {
            super.init(frame: frame)
            wantsLayer = true

            let path = CGPath(
                roundedRect: bounds,
                cornerWidth: cornerRadius,
                cornerHeight: cornerRadius,
                transform: nil
            )
            let clip = CAShapeLayer()
            clip.frame = bounds
            clip.path = path
            clip.fillColor = NSColor.white.cgColor
            layer?.mask = clip

            /* The vertical band (in points from the top/bottom edge) inside
               which the specular fades: just past the corner arcs, so the
               highlight visibly wraps the corners and lets go. */
            let band = min(cornerRadius * 1.6, bounds.height / 4)
            let t = NSNumber(value: band / bounds.height)
            let tIn = NSNumber(value: 0.5 * band / bounds.height)
            let fromBottom = NSNumber(value: 1 - band / bounds.height)
            let fromBottomIn = NSNumber(value: 1 - 0.5 * band / bounds.height)

            func line(
                width: CGFloat, colors: [NSColor], locations: [NSNumber], compositing: String?
            ) -> CAGradientLayer {
                let strokeMask = CAShapeLayer()
                strokeMask.frame = bounds
                strokeMask.path = path
                strokeMask.fillColor = nil
                strokeMask.strokeColor = NSColor.white.cgColor
                strokeMask.lineWidth = width

                let gradient = CAGradientLayer()
                gradient.frame = bounds
                /* Unflipped layer space: start (0.5, 1) is the top edge. */
                gradient.startPoint = CGPoint(x: 0.5, y: 1)
                gradient.endPoint = CGPoint(x: 0.5, y: 0)
                gradient.colors = colors.map(\.cgColor)
                gradient.locations = locations
                gradient.mask = strokeMask
                gradient.compositingFilter = compositing
                return gradient
            }

            let clear = NSColor.white.withAlphaComponent(0)
            /* Faint dark hairline down the straight sides, fading in only
               after the corner arcs end so it never dirties the highlight. */
            let dark = line(
                width: 1.5,
                colors: [
                    clear, .black.withAlphaComponent(0.10),
                    .black.withAlphaComponent(0.10), clear,
                ],
                locations: [tIn, t, fromBottom, fromBottomIn],
                compositing: nil)
            /* One tight additive glow instead of Transom's three: on a big
               panel a wide glow reads as haze, not glass. */
            let glow = line(
                width: 5,
                colors: [
                    .white.withAlphaComponent(0.10), clear,
                    clear, .white.withAlphaComponent(0.07),
                ],
                locations: [0, t, fromBottom, 1],
                compositing: "plusL")
            /* The crisp specular line: brightest along the top edge (the
               light "comes from above"), weaker along the bottom, gone on
               the sides where the dark hairline takes over. */
            let bright = line(
                width: 1.5,
                colors: [
                    .white.withAlphaComponent(0.55), clear,
                    clear, .white.withAlphaComponent(0.35),
                ],
                locations: [0, t, fromBottom, 1],
                compositing: "plusL")
            layer?.addSublayer(dark)
            layer?.addSublayer(glow)
            layer?.addSublayer(bright)
        }

        required init?(coder: NSCoder) { fatalError("unused") }
    }
}

/* One window in the grid: a window preview above a title line, with the
   owning app's icon as a badge. Cards seed from the preview cache so
   reopening the switcher never flashes back to icons; a fresh capture
   replaces the image in place when it lands (off-screen windows included,
   via the SkyLight backing-store path). The centered app icon only shows
   when every capture path came up empty — most commonly without Screen
   Recording permission — dimmed for windows not on screen.

   Colors are semantic: black-on-bright-glass in light mode, white-on-dark
   in dark mode, matching the panel's appearance-dependent material. */
final class SwitcherItemView: NSView {
    static let size = CGSize(width: 180, height: 140)
    private static let thumbnailFrame = NSRect(
        x: 8, y: 32,
        width: PreviewLoader.thumbnailBox.width, height: PreviewLoader.thumbnailBox.height)

    private let highlightView = NSView()
    private let thumbnailView = NSImageView()
    private let placeholderIcon = NSImageView()
    private let badgeIcon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let title: String
    private let titleColor: NSColor

    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var isSelected = false {
        didSet {
            highlightView.isHidden = !isSelected
            needsDisplay = true
            updateLabel()
        }
    }

    init(window: SwitcherWindow) {
        /* The Window-menu convention: minimized windows carry a diamond
           before their title. A system-wide symbol, so no localization. */
        title = (window.isMinimized ? "◆ " : "") + window.title
        titleColor = window.isBackground ? .secondaryLabelColor : .labelColor
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true

        /* The selection scrim hugs the preview area only, leaving the title
           line below it unhighlighted. 8pt of air on every side (its bottom
           edge just meets the label frame's top) with a generous corner. */
        highlightView.frame = Self.thumbnailFrame.insetBy(dx: -8, dy: -8)
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 16
        highlightView.layer?.cornerCurve = .continuous
        highlightView.isHidden = true
        addSubview(highlightView)

        thumbnailView.frame = Self.thumbnailFrame
        thumbnailView.imageScaling = .scaleProportionallyDown
        addSubview(thumbnailView)

        let iconSide: CGFloat = 64
        placeholderIcon.frame = NSRect(
            x: Self.thumbnailFrame.midX - iconSide / 2,
            y: Self.thumbnailFrame.midY - iconSide / 2,
            width: iconSide, height: iconSide)
        placeholderIcon.image = window.app.icon
        placeholderIcon.imageScaling = .scaleProportionallyUpOrDown
        placeholderIcon.alphaValue = window.isBackground ? 0.45 : 1
        addSubview(placeholderIcon)

        /* Once a preview replaces the centered icon, the app identity moves
           to a small badge over the thumbnail's bottom-right corner. */
        let badgeSide: CGFloat = 28
        badgeIcon.frame = NSRect(
            x: Self.thumbnailFrame.maxX - badgeSide - 2,
            y: Self.thumbnailFrame.minY + 2,
            width: badgeSide, height: badgeSide)
        badgeIcon.image = window.app.icon
        badgeIcon.imageScaling = .scaleProportionallyUpOrDown
        badgeIcon.isHidden = true
        addSubview(badgeIcon)

        label.frame = NSRect(x: 8, y: 8, width: Self.size.width - 16, height: 16)
        updateLabel()
        addSubview(label)

        /* Last-known preview, immediately: keeps reopening flicker-free and
           gives minimized windows a meaningful picture from before they
           were minimized. */
        if let id = window.windowID, let cached = PreviewLoader.cachedImage(for: id) {
            showPreview(cached)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func showPreview(_ image: NSImage) {
        thumbnailView.image = image
        placeholderIcon.isHidden = true
        badgeIcon.isHidden = false
    }

    /* Selection emboldens the title WITHOUT reflow: a real bold font has
       wider glyphs, which would shift the centered text and move the
       truncation point. A negative strokeWidth instead outlines each glyph
       in its own fill color — visually bold, metrically identical. */
    private func updateLabel() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11.5),
            .foregroundColor: titleColor,
            .paragraphStyle: paragraph,
        ]
        if isSelected {
            attributes[.strokeWidth] = -4.5
        }
        label.attributedStringValue = NSAttributedString(string: title, attributes: attributes)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        /* Opposed to the glass face: a dark scrim on the bright light-mode
           glass, a bright one on the dark glass — either way the highlight
           stands out instead of washing into the material. */
        let isDark =
            effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let highlight =
            isDark
            ? NSColor.white.withAlphaComponent(0.35)
            : NSColor.black.withAlphaComponent(0.25)
        highlightView.layer?.backgroundColor = highlight.cgColor
    }

    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) {
            onClick?()
        }
    }

    /* .activeAlways: the panel is non-activating and never key, so the
       default active-in-key-window tracking would never fire. .mouseMoved
       as well as enter/exit: a cursor that is already inside a card when
       the panel opens never "enters" it — the first slight motion has to
       be enough to claim the hover. */
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?()
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?()
    }
}
