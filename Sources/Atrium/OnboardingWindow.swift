import AppKit
import Carbon.HIToolbox

/* First-run onboarding: what Atrium is, what the switcher looks like, the
   shortcuts, and the permission gates. Accessibility is required (it's how
   windows are listed and raised) and gates the Start button; Screen
   Recording is optional (window previews — without it the switcher shows
   app icons) and never blocks. The window has no close button and refuses
   every close attempt — the only way out is granting access and clicking
   Start, and completion is persisted only at that click, so quitting (or
   force-quitting) mid-onboarding brings the onboarding back on the next
   launch. */
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onComplete: () -> Void
    private var pollTimer: Timer?
    /* Screen Recording only takes effect at process launch: a grant made
       while Atrium is running needs a relaunch, and comparing against the
       state at init is what tells the two cases apart. */
    private let screenRecordingGrantedAtLaunch = CGPreflightScreenCaptureAccess()

    private let accessibilityStatus = NSTextField(labelWithString: "")
    private lazy var accessibilityButton = NSButton(
        title: L("Request Accessibility Access"), target: self,
        action: #selector(requestAccessibility))
    private lazy var accessibilityLink = NSButton(
        title: L("Open Privacy & Security Settings…"), target: self,
        action: #selector(openAccessibilitySettings))

    private let recordingStatus = NSTextField(labelWithString: "")
    private lazy var recordingButton = NSButton(
        title: L("Enable Window Previews…"), target: self,
        action: #selector(requestScreenRecording))

    private lazy var startButton = NSButton(
        title: L("Start Using Atrium"), target: self, action: #selector(start))

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete

        /* No .closable: the traffic-light close button never appears. */
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent()
        window.center()

        refreshPermissionState()
        /* Permission grants don't notify; polling once a second is the
           standard idiom (the System Settings toggle takes effect live). */
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) {
            [weak self] _ in
            self?.refreshPermissionState()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /* The gate: no closing until onboarding is completed via start(). */
    func windowShouldClose(_ sender: NSWindow) -> Bool { false }

    // MARK: - Content

    private func makeContent() -> NSView {
        let title = NSTextField(labelWithString: L("Welcome to Atrium"))
        title.font = .systemFont(ofSize: 30, weight: .bold)

        let intro = NSTextField(
            wrappingLabelWithString:
                L("Atrium switches between windows, not just apps: one shortcut shows every window of every app — minimized ones included — as live previews, on whichever screen your cursor is."))
        intro.font = .systemFont(ofSize: 14)
        intro.textColor = .secondaryLabelColor
        intro.alignment = .center
        intro.preferredMaxLayoutWidth = 470

        let illustration = OnboardingIllustrationView()
        illustration.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            illustration.widthAnchor.constraint(equalToConstant: 480),
            illustration.heightAnchor.constraint(equalToConstant: 190),
        ])

        let shortcutRow = NSStackView(
            views: [
                labelView(L("Hold")),
                keycap("⌥"),
                labelView(L("and tap")),
                keycap("⇥"),
                labelView(L("— or")),
                keycap("`"),
                labelView(L("for this app only")),
            ])
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = 6

        accessibilityStatus.font = .systemFont(ofSize: 13)
        accessibilityButton.bezelStyle = .rounded
        accessibilityButton.keyEquivalent = "\r"
        accessibilityLink.isBordered = false
        accessibilityLink.contentTintColor = .linkColor
        accessibilityLink.font = .systemFont(ofSize: 12)

        recordingStatus.font = .systemFont(ofSize: 13)
        recordingButton.bezelStyle = .rounded

        let permissionBox = NSStackView(
            views: [
                accessibilityStatus, accessibilityButton, accessibilityLink,
                recordingStatus, recordingButton,
            ])
        permissionBox.orientation = .vertical
        permissionBox.alignment = .centerX
        permissionBox.spacing = 8
        permissionBox.setCustomSpacing(18, after: accessibilityLink)

        startButton.bezelStyle = .rounded
        startButton.controlSize = .large

        let stack = NSStackView(
            views: [title, intro, illustration, shortcutRow, permissionBox, startButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.setCustomSpacing(10, after: title)
        stack.setCustomSpacing(22, after: intro)
        stack.setCustomSpacing(24, after: shortcutRow)
        stack.setCustomSpacing(20, after: permissionBox)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 44),
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.bottomAnchor.constraint(
                lessThanOrEqualTo: container.bottomAnchor, constant: -32),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 500),
        ])
        return container
    }

    private func labelView(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func keycap(_ symbol: String) -> NSView {
        KeycapView(symbol: symbol)
    }

    // MARK: - Permission gates

    private func refreshPermissionState() {
        let trusted = AXIsProcessTrusted()
        accessibilityStatus.stringValue =
            trusted
            ? L("✓ Accessibility access granted")
            : L("Atrium needs Accessibility access to list and raise windows.")
        accessibilityStatus.textColor = trusted ? .systemGreen : .labelColor
        accessibilityButton.isHidden = trusted
        accessibilityLink.isHidden = trusted
        startButton.isEnabled = trusted
        startButton.keyEquivalent = trusted ? "\r" : ""

        let recording = CGPreflightScreenCaptureAccess()
        if recording {
            recordingStatus.stringValue =
                screenRecordingGrantedAtLaunch
                ? L("✓ Screen Recording granted — window previews enabled")
                : L("✓ Screen Recording granted — previews start on the next launch")
            recordingStatus.textColor = .systemGreen
        } else {
            recordingStatus.stringValue =
                L("Optional: Screen Recording shows live window previews (icons otherwise).")
            recordingStatus.textColor = .secondaryLabelColor
        }
        recordingButton.isHidden = recording
    }

    @objc private func requestAccessibility() {
        /* The system prompt appears only on the very first ask; afterwards
           macOS stays silent, so the settings link below is the fallback. */
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    @objc private func openAccessibilitySettings() {
        guard
            let url = URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security"
                    + "?Privacy_Accessibility")
        else { return }
        NSWorkspace.shared.open(url)
    }

    /* Prompts once; if the system prompt was already used up, this opens
       the Screen Recording pane instead so the button always does something. */
    @objc private func requestScreenRecording() {
        if !CGRequestScreenCaptureAccess() {
            guard
                let url = URL(
                    string:
                        "x-apple.systempreferences:com.apple.preference.security"
                        + "?Privacy_ScreenCapture")
            else { return }
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func start() {
        guard AXIsProcessTrusted() else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        window?.delegate = nil
        onComplete()
        close()
    }
}

/* One keyboard key, drawn as a keycap. */
private final class KeycapView: NSView {
    private let symbol: String

    init(symbol: String) {
        self.symbol = symbol
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 34),
            heightAnchor.constraint(equalToConstant: 30),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
        NSColor.quaternarySystemFill.setFill()
        body.fill()
        NSColor.separatorColor.setStroke()
        body.lineWidth = 1
        body.stroke()

        let text = NSAttributedString(
            string: symbol,
            attributes: [
                .font: NSFont.systemFont(ofSize: 15, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ])
        let size = text.size()
        text.draw(
            at: NSPoint(
                x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }
}

/* A drawn "screenshot" of the switcher in action: the glass panel over a
   desktop, a row of window-preview cards with the selected one highlighted.
   Drawn (not a bundled image) so it stays crisp at any backing scale and
   needs no resource plumbing. */
private final class OnboardingIllustrationView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let canvas = bounds

        // Desktop backdrop, in Atrium's dusk pink-on-navy
        let backdrop = NSBezierPath(roundedRect: canvas, xRadius: 12, yRadius: 12)
        NSGradient(
            starting: NSColor(srgbRed: 0.16, green: 0.12, blue: 0.24, alpha: 1),
            ending: NSColor(srgbRed: 0.07, green: 0.05, blue: 0.13, alpha: 1)
        )?.draw(in: backdrop, angle: -90)

        // A couple of "desktop windows" peeking out behind the panel
        for (rect, alpha) in [
            (NSRect(x: 30, y: 96, width: 170, height: 80), 0.16),
            (NSRect(x: 300, y: 82, width: 150, height: 92), 0.12),
        ] {
            NSColor.white.withAlphaComponent(alpha).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        }

        // The switcher panel: light glass slab, centered
        let panel = NSRect(x: 60, y: 34, width: 360, height: 110)
        let panelPath = NSBezierPath(roundedRect: panel, xRadius: 22, yRadius: 22)
        NSColor.white.withAlphaComponent(0.82).setFill()
        panelPath.fill()
        NSColor.white.withAlphaComponent(0.5).setStroke()
        panelPath.lineWidth = 1
        panelPath.stroke()

        // Four preview cards; the second selected. Insets are computed so
        // the card row and the title lines sit centered in the panel.
        let cardWidth: CGFloat = 78
        let cardHeight: CGFloat = 52
        let gap: CGFloat = 8
        let cardCount = 4
        let rowWidth = CGFloat(cardCount) * cardWidth + CGFloat(cardCount - 1) * gap
        /* Content block: title line (5pt) + 13pt air + card (52pt). */
        let titleHeight: CGFloat = 5
        let titleGap: CGFloat = 13
        let contentHeight = titleHeight + titleGap + cardHeight
        let contentBottom = panel.minY + (panel.height - contentHeight) / 2
        var x = panel.minX + (panel.width - rowWidth) / 2
        for index in 0..<cardCount {
            let card = NSRect(
                x: x, y: contentBottom + titleHeight + titleGap,
                width: cardWidth, height: cardHeight)
            if index == 1 {
                let highlight = card.insetBy(dx: -5, dy: -5)
                NSColor.black.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: highlight, xRadius: 10, yRadius: 10).fill()
            }
            // The "window preview": a mini window with a title bar
            NSColor(srgbRed: 0.72, green: 0.74, blue: 0.85, alpha: 1).setFill()
            NSBezierPath(roundedRect: card, xRadius: 5, yRadius: 5).fill()
            NSColor(srgbRed: 0.88, green: 0.89, blue: 0.95, alpha: 1).setFill()
            NSBezierPath(
                roundedRect: NSRect(
                    x: card.minX, y: card.maxY - 12, width: card.width, height: 12),
                xRadius: 5, yRadius: 5
            ).fill()
            // Title line under the card, bolder for the selected one
            let titleWidth: CGFloat = index == 1 ? 46 : 36
            NSColor.black.withAlphaComponent(index == 1 ? 0.75 : 0.35).setFill()
            NSBezierPath(
                roundedRect: NSRect(
                    x: card.midX - titleWidth / 2, y: contentBottom,
                    width: titleWidth, height: titleHeight),
                xRadius: 2.5, yRadius: 2.5
            ).fill()
            x += cardWidth + gap
        }
    }
}
