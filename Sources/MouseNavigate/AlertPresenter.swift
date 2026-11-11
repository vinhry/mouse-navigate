import AppKit

/// Every alert the app puts up, built one way and shown from the right context.
@MainActor
enum AlertPresenter {
    static func make(
        _ title: String,
        _ message: String,
        style: NSAlert.Style = .informational,
        buttons: [String] = []
    ) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        for button in buttons {
            alert.addButton(withTitle: button)
        }
        return alert
    }

    /// An alert whose first button throws something away. Marked as destructive, that
    /// button no longer answers Return, so a stray Return cannot do it. The last button
    /// keeps Escape; making it the Return button instead would take Escape from it.
    static func makeDestructive(_ title: String, _ message: String, buttons: [String]) -> NSAlert {
        let alert = make(title, message, buttons: buttons)
        let destructive = alert.buttons[0]
        destructive.hasDestructiveAction = true
        destructive.keyEquivalent = ""
        return alert
    }

    /// A destructive alert on `window`, as a sheet; `confirmed` runs only if the first
    /// button is chosen.
    static func confirmDestructive(
        _ title: String,
        _ message: String,
        confirm: String,
        on window: NSWindow,
        then confirmed: @escaping () -> Void
    ) {
        makeDestructive(title, message, buttons: [confirm, "Cancel"])
            .beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { confirmed() }
            }
    }

    /// On `window`, as a sheet. With no buttons named, the alert has a single OK.
    static func sheet(
        _ title: String,
        _ message: String,
        style: NSAlert.Style = .informational,
        buttons: [String] = [],
        on window: NSWindow,
        then handle: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
        make(title, message, style: style, buttons: buttons).beginSheetModal(for: window, completionHandler: handle)
    }

    /// In front of everything, for an app that usually has no window to put a sheet on.
    ///
    /// `NSAlert.runModal()` spins a nested run loop. Entered from a block on the main
    /// dispatch queue, that loop serves no other main-queue block until the alert closes,
    /// so the keyboard cursor's hold timer never fires, side buttons with a hold binding
    /// swallow their presses and gesture actions queue up. Entered from the run loop
    /// itself, it serves everything as usual, so that is where it is always entered from,
    /// whatever context the caller is in.
    static func modal(
        _ title: String,
        _ message: String,
        style: NSAlert.Style = .informational,
        buttons: [String] = [],
        then handle: @escaping (NSApplication.ModalResponse) -> Void = { _ in }
    ) {
        let alert = make(title, message, style: style, buttons: buttons)
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
            NSApp.activate(ignoringOtherApps: true)
            handle(alert.runModal())
        }
        CFRunLoopWakeUp(main)
    }
}
