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
       and the next reveal re-commits stock glass material — 1% keeps it
       attached while being imperceptible. */
    private static let hiddenAlpha: CGFloat = 0.01

    var onItemClick: ((Int) -> Void)?
    var onItemHover: ((Int) -> Void)?
    /// Whether the switcher is currently presented. Not `isVisible`: the
    /// panel stays ordered in at 1% alpha forever (see hiddenAlpha).
    private(set) var isPresented = false
    /// Items per full row in the current layout — the stride for moving
    /// the selection vertically with the arrow keys.
    private(set) var columns = 1

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
        layout(windows: windows, on: screen)
        select(selectedIndex)
        isPresented = true
        ignoresMouseEvents = false
        /* Zero-duration animator write: replaces any in-flight fade where a
           plain alphaValue assignment would race it. */
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().alphaValue = 1
        }
        orderFrontRegardless()
    }

    /// Sizes and populates the dormant panel without presenting it. Called
    /// once shortly after launch: the first real show then (usually) needs
    /// no resize, and it's the resize that momentarily flashes stock
    /// frosted material before the re-tune lands.
    func preLayout(windows: [SwitcherWindow], on screen: NSScreen) {
        guard !isPresented else { return }
        layout(windows: windows, on: screen)
    }

    private func layout(windows: [SwitcherWindow], on screen: NSScreen) {
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
           tight cadence, since the re-commit lands a frame or two after the
           resize and anything slower shows as a frosted flash. */
        tuneGlassMaterial()
        if resized {
            for delay in [0.05, 0.15, 0.3, 0.7] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.tuneGlassMaterial()
                }
            }
        }
    }

    /* Alpha-only, never to zero, never ordered out: both would reset the
       tuned material (see init). */
    func dismiss() {
        isPresented = false
        ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().alphaValue = Self.hiddenAlpha
        }
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
        columns = perRow

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
        let white = isDark ? 0.76 : 0.96
        let black = isDark ? 0.07 : 0.09
        let maxLuma = isDark ? 0.72 : 0.92
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
            NSColor.white.withAlphaComponent(0).cgColor,
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
   replaces the image in place when it lands. Only windows that were never
   captured (first sight while minimized, or no Screen Recording permission)
   show the centered app icon, dimmed for windows not on screen.

   Colors are semantic: black-on-bright-glass in light mode, white-on-dark
   in dark mode, matching the panel's appearance-dependent material. */
final class SwitcherItemView: NSView {
    static let size = CGSize(width: 180, height: 140)
    private static let thumbnailFrame = NSRect(
        x: 8, y: 32,
        width: PreviewLoader.thumbnailBox.width, height: PreviewLoader.thumbnailBox.height)

    private let thumbnailView = NSImageView()
    private let placeholderIcon = NSImageView()
    private let badgeIcon = NSImageView()

    var onClick: (() -> Void)?
    var onHover: (() -> Void)?
    var isSelected = false {
        didSet { needsDisplay = true }
    }

    init(window: SwitcherWindow) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous

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

        let label = NSTextField(labelWithString: window.title)
        label.font = .systemFont(ofSize: 11.5)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.textColor = window.isBackground ? .secondaryLabelColor : .labelColor
        label.frame = NSRect(x: 8, y: 8, width: Self.size.width - 16, height: 16)
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
        layer?.backgroundColor = isSelected ? highlight.cgColor : nil
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
