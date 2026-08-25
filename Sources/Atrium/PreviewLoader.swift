import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers

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
    static func load(
        for windows: [SwitcherWindow], apply: @escaping (Int, NSImage) -> Void
    ) -> Task<Void, Never>? {
        guard CGPreflightScreenCaptureAccess() else { return nil }
        /* Windows that closed since the last invocation won't be listed
           again — drop their cached previews, on disk too. */
        let liveIDs = Set(windows.compactMap(\.windowID))
        cache = cache.filter { liveIDs.contains($0.key) }
        pruneDisk(keeping: liveIDs)
        return Task {
            /* onScreenWindowsOnly: false so windows on other Spaces (which
               the switcher lists as regular entries) get previews too. */
            guard
                let content = try? await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: false)
            else { return }
            let byID = Dictionary(
                content.windows.map { ($0.windowID, $0) },
                uniquingKeysWith: { first, _ in first })
            await withTaskGroup(of: Void.self) { group in
                for (index, window) in windows.enumerated() {
                    /* Minimized windows and hidden apps have no live pixels
                       to capture — their cards keep the cached preview from
                       before they left the screen, or the app icon. */
                    guard !window.isBackground,
                        let id = window.windowID,
                        let scWindow = byID[id]
                    else { continue }
                    group.addTask {
                        guard let (image, cgImage) = await capture(scWindow) else { return }
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
}
