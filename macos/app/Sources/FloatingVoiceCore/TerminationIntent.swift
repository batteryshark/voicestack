import Foundation
import Carbon

/// Fail closed: an arbitrary termination callback is not evidence of deliberate Quit.
/// App menus mark explicit intent; Dock Quit supplies an ordinary quit Apple event.
/// A system quit reason (including unknown future values) always wins over either.
public enum TerminationIntent {
    public static func isDeliberateQuit(explicit: Bool, appleEvent: NSAppleEventDescriptor?) -> Bool {
        let quitEvent = appleEvent?.eventClass == AEEventClass(kCoreEventClass) && appleEvent?.eventID == AEEventID(kAEQuitApplication)
        // `why?` is a parameter, not an attribute. Reject even unknown future system reasons.
        return isDeliberateQuit(explicit: explicit, quitAppleEvent: quitEvent,
                                hasSystemReason: appleEvent?.paramDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil)
    }

    public static func isDeliberateQuit(explicit: Bool, quitAppleEvent: Bool, hasSystemReason: Bool) -> Bool {
        !hasSystemReason && (explicit || quitAppleEvent)
    }
}

/// The production delegate's one-shot intent adapter, independently exercisable without NSApplication.
public struct QuitIntentGate {
    private var explicit = false
    public init() {}
    public mutating func requestQuit() { explicit = true }
    public mutating func consume(appleEvent: NSAppleEventDescriptor?) -> Bool {
        defer { explicit = false }
        return TerminationIntent.isDeliberateQuit(explicit: explicit, appleEvent: appleEvent)
    }
}
