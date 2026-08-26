import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

/* Capture for windows with no on-screen pixels — minimized, hidden (⌘H),
   even ones never shown since launch. The window server retains every
   window's last backing store (it's what the Dock's minimized thumbnails
   show), and SkyLight's private SLSHWCaptureWindowList reads it directly;
   ScreenCaptureKit only captures what is actually rendered on screen.

   Resolved with dlsym at runtime rather than linked: if a future macOS
   drops the symbols, `capture` is nil and the loader quietly falls back to
   cached previews and app icons — no link failure, no crash. */
private enum SkyLight {
    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias HWCaptureWindowList = @convention(c) (
        Int32, UnsafeMutablePointer<CGWindowID>, Int32, UInt32
    ) -> Unmanaged<CFArray>?

    /* 1 << 11: ignore the global clip shape; 1 << 9: nominal (point)
       resolution — plenty for thumbnails, cheaper than best. */
    private static let options: UInt32 = 1 << 11 | 1 << 9

    static let capture: ((CGWindowID) -> CGImage?)? = {
        guard
            let handle = dlopen(
                "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
            let connectionSymbol = dlsym(handle, "SLSMainConnectionID"),
            let captureSymbol = dlsym(handle, "SLSHWCaptureWindowList")
        else { return nil }
        let connection = unsafeBitCast(connectionSymbol, to: MainConnectionID.self)()
        let captureList = unsafeBitCast(captureSymbol, to: HWCaptureWindowList.self)
        return { windowID in
            var id = windowID
            guard
                let images = captureList(connection, &id, 1, options)?
                    .takeRetainedValue() as? [AnyObject],
                let first = images.first,
                CFGetTypeID(first) == CGImage.typeID
            else { return nil }
            return (first as! CGImage)
        }
    }()
}

/* One-shot window screenshots for the switcher, via ScreenCaptureKit (the
   old CGWindowList imaging is defunct on modern macOS). Previews stream in
   asynchronously so the panel never waits on a capture: it opens with app
   icons and upgrades each card as its screenshot lands. */
enum PreviewLoader {
    /// Display size of a card's thumbnail area, in points — captures are
    /// scaled to fit this box (at 2x) so no bytes are wasted.
    static let thumbnailBox = CGSize(width: 164, height: 96)

    /* Last capture per window, so reopening the switcher shows pictures
       immediately instead of flashing icons while captures re-run, and so
       minimized windows keep the preview from before they were minimized.
       Main-thread only. Backed by a disk copy (see diskDirectory) so the
       previews survive Atrium relaunches — without it, a window that was
       already minimized at launch could never show anything but its icon. */
    private static var cache: [CGWindowID: NSImage] = [:]

    private static let diskQueue = DispatchQueue(
        label: "com.jhaemin.atrium.preview-cache", qos: .utility)

    /* One PNG per window under ~/Library/Caches. CGWindowIDs are only
       unique within one boot session — after a reboot they restart and an
       old file could attach a stale preview to an unrelated new window —
       so the directory carries a boot-time marker and is wiped whenever it
       doesn't match. */
    private static let diskDirectory: URL? = {
        guard
            let caches = FileManager.default.urls(
                for: .cachesDirectory, in: .userDomainMask
            ).first
        else { return nil }
        let directory = caches.appendingPathComponent(
            "com.jhaemin.atrium/previews", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &bootTime, &size, nil, 0)
        let marker = directory.appendingPathComponent("session")
        let current = "\(bootTime.tv_sec)"
        if (try? String(contentsOf: marker, encoding: .utf8)) != current {
            let stale =
                (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in stale {
                try? FileManager.default.removeItem(at: file)
            }
            try? current.write(to: marker, atomically: true, encoding: .utf8)
        }
        return directory
    }()

    static func cachedImage(for id: CGWindowID) -> NSImage? {
        if let image = cache[id] {
            return image
        }
        /* Miss: fall back to the disk copy from a previous run. Loaded
           lazily per window (not all at launch) and promoted into the
           memory cache. */
        guard
            let url = diskDirectory?.appendingPathComponent("\(id).png"),
            let image = NSImage(contentsOf: url)
        else { return nil }
        cache[id] = image
        return image
    }

    private static func persistToDisk(_ image: CGImage, id: CGWindowID) {
        guard let directory = diskDirectory else { return }
        diskQueue.async {
            let url = directory.appendingPathComponent("\(id).png")
            guard
                let destination = CGImageDestinationCreateWithURL(
                    url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
    }

    private static func pruneDisk(keeping liveIDs: Set<CGWindowID>) {
        guard let directory = diskDirectory else { return }
        diskQueue.async {
            let files =
                (try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "png" {
                guard
                    let id = CGWindowID(file.deletingPathExtension().lastPathComponent),
                    !liveIDs.contains(id)
                else { continue }
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Kicks off captures for every capturable window and calls `apply` on
    /// the main actor as each preview arrives. Returns nil (icons-only mode)
    /// without Screen Recording permission. Cancel the task to discard
    /// in-flight captures when the panel hides.
    ///
    /// `isCompleteList` must be false for scoped invocations (Option+`,
    /// frontmost app only): pruning treats absence from the list as "window
    /// closed", and pruning against a filtered list would evict every other
    /// window's cached preview — making the next all-windows switch flicker
    /// through icons while everything re-captures.
    static func load(
        for windows: [SwitcherWindow], isCompleteList: Bool = true,
        apply: @escaping (Int, NSImage) -> Void
    ) -> Task<Void, Never>? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        /* Windows that closed since the last invocation won't be listed
           again — drop their cached previews, on disk too. */
        if isCompleteList {
            let liveIDs = Set(windows.compactMap(\.windowID))
            cache = cache.filter { liveIDs.contains($0.key) }
            pruneDisk(keeping: liveIDs)
        }
        return Task {
            /* onScreenWindowsOnly: false so windows on other Spaces (which
               the switcher lists as regular entries) get previews too. A
               failed fetch must NOT end the whole load — every window can
               still try the SkyLight backing-store path below. */
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: false)
            let byID = Dictionary(
                (content?.windows ?? []).map { ($0.windowID, $0) },
                uniquingKeysWith: { first, _ in first })
            await withTaskGroup(of: Void.self) { group in
                for (index, window) in windows.enumerated() {
                    guard let id = window.windowID else { continue }
                    /* On-screen windows go through ScreenCaptureKit; ones
                       with no live pixels (minimized, hidden apps) skip
                       straight to the window server's retained backing
                       store via SkyLight. */
                    let scWindow = window.isBackground ? nil : byID[id]
                    group.addTask {
                        var result: (NSImage, CGImage)?
                        if let scWindow {
                            result = await capture(scWindow)
                        }
                        if result == nil {
                            result = captureBackingStore(id)
                        }
                        /* Both paths failed: the card keeps its cached
                           preview from a previous run, or the app icon. */
                        guard let (image, cgImage) = result else { return }
                        /* Already off the main thread here — encode and
                           write the disk copy without touching the UI. */
                        persistToDisk(cgImage, id: id)
                        await MainActor.run {
                            guard !Task.isCancelled else { return }
                            cache[id] = image
                            apply(index, image)
                        }
                    }
                }
            }
        }
    }

    /* One-shot report for remote debugging: permission state, both capture
       paths' availability, and a per-window verdict — copyable by a tester
       in one click (the status menu's Copy Diagnostics). */
    static func diagnostics() async -> String {
        var lines: [String] = ["Atrium diagnostics"]
        let info = Bundle.main.infoDictionary
        lines.append(
            "version: \(info?["CFBundleShortVersionString"] as? String ?? "dev")"
                + " (\(info?["CFBundleVersion"] as? String ?? "-"))")
        lines.append("screen recording preflight: \(CGPreflightScreenCaptureAccess())")
        lines.append("SkyLight capture available: \(SkyLight.capture != nil)")

        let content = try? await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        lines.append(
            "SCShareableContent: "
                + (content.map { "\($0.windows.count) windows" } ?? "FAILED"))
        let byID = Dictionary(
            (content?.windows ?? []).map { ($0.windowID, $0) },
            uniquingKeysWith: { first, _ in first })

        for window in WindowEnumerator.list() {
            let name = window.app.localizedName ?? "?"
            let title = window.title.prefix(18)
            guard let id = window.windowID else {
                lines.append("\(name) '\(title)': no windowID")
                continue
            }
            var verdict: [String] = []
            verdict.append(window.isBackground ? "background" : "on-screen")
            verdict.append(byID[id] != nil ? "in-SCK-list" : "NOT-in-SCK-list")
            if !window.isBackground, let scWindow = byID[id] {
                verdict.append(await capture(scWindow) != nil ? "sck-ok" : "sck-FAIL")
            }
            verdict.append(captureBackingStore(id) != nil ? "skylight-ok" : "skylight-FAIL")
            verdict.append(cachedImage(for: id) != nil ? "cached" : "no-cache")
            lines.append("\(name) '\(title)': \(verdict.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func capture(_ window: SCWindow) async -> (NSImage, CGImage)? {
        let frame = window.frame
        guard frame.width > 0, frame.height > 0 else { return nil }
        let scale = min(
            thumbnailBox.width / frame.width, thumbnailBox.height / frame.height, 1)
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(frame.width * scale * 2))
        configuration.height = max(1, Int(frame.height * scale * 2))
        configuration.showsCursor = false
        guard
            let cgImage = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window),
                configuration: configuration)
        else { return nil }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: frame.width * scale, height: frame.height * scale))
        return (image, cgImage)
    }

    /* SkyLight capture of a window's retained backing store — the only way
       to picture minimized/hidden windows, including ones never shown since
       launch. Returns nil when the private API is unavailable or declines
       (e.g. nothing retained for the window yet). */
    private static func captureBackingStore(_ id: CGWindowID) -> (NSImage, CGImage)? {
        guard let capture = SkyLight.capture, let raw = capture(id) else { return nil }
        return downscale(raw)
    }

    /* SkyLight returns the window at its nominal size — scale it down to
       the thumbnail box (at 2x) like the ScreenCaptureKit path, so cache
       entries stay small and uniform. */
    private static func downscale(_ image: CGImage) -> (NSImage, CGImage)? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard width > 0, height > 0 else { return nil }
        let scale = min(
            thumbnailBox.width * 2 / width, thumbnailBox.height * 2 / height, 1)
        let scaledWidth = max(1, Int(width * scale))
        let scaledHeight = max(1, Int(height * scale))
        guard
            let context = CGContext(
                data: nil, width: scaledWidth, height: scaledHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.interpolationQuality = .high
        context.draw(
            image, in: CGRect(x: 0, y: 0, width: scaledWidth, height: scaledHeight))
        guard let scaled = context.makeImage() else { return nil }
        let pointSize = NSSize(
            width: CGFloat(scaledWidth) / 2, height: CGFloat(scaledHeight) / 2)
        return (NSImage(cgImage: scaled, size: pointSize), scaled)
    }
}
