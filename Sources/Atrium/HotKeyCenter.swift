import Carbon.HIToolbox
import Foundation

/* System-wide hotkeys via Carbon's RegisterEventHotKey — ancient but still
   the supported API for global shortcuts. Unlike an event tap it needs no
   extra permission, it consumes the keystroke (the focused app never sees
   Option+Tab), and it works from a plain non-bundled binary, which keeps
   `swift run` viable for development. */
final class HotKeyCenter {
    private var handlers: [UInt32: () -> Void] = [:]
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    /* Process-wide, not per-center: the fired event carries only the id, and
       every center's handler sees every event — colliding ids would make one
       center run its own handler for another center's hotkey. */
    private static var nextID: UInt32 = 1
    private static let signature = OSType(0x4154_524D)  // 'ATRM'

    init() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let userData, let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                /* Several HotKeyCenters coexist (app shortcuts + the
                   switcher's transient Escape), each with its own handler on
                   the same event target. Carbon calls them newest-first and
                   noErr stops the chain — so an id this center doesn't own
                   must be passed along, not swallowed. */
                guard let handler = center.handlers[hotKeyID.id] else {
                    return OSStatus(eventNotHandledErr)
                }
                handler()
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
    }

    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        let id = Self.nextID
        Self.nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            /* -9878 (eventHotKeyExistsErr) means another app owns the combo
               — worth surfacing, since the failure is otherwise silent. */
            NSLog(
                "Atrium: failed to register hotkey (keyCode %u, modifiers %u): OSStatus %d",
                keyCode, modifiers, status)
            return false
        }
        handlers[id] = handler
        hotKeyRefs[id] = ref
        return true
    }

    /* The switcher registers keys like plain Escape only while its panel is
       up — a permanently registered Escape would swallow the key system-wide
       — so releasing everything on hide must be cheap and reliable. */
    func unregisterAll() {
        for ref in hotKeyRefs.values {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        handlers.removeAll()
    }
}
