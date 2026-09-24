import Foundation

let navigator = MouseNavigator()
navigator.isTouchDebugEnabled = CommandLine.arguments.contains("--touch-debug")

if CommandLine.arguments.contains("--list-devices") {
    // Support aid: shows what the detector sees without needing any permissions.
    navigator.printDetectedDevices()
} else {
    // One process, however it was started. Earlier versions spawned a detached copy of
    // themselves with "--daemon" and let this one exit; the flag is still accepted and
    // ignored, so a login item registered by such a version keeps working.
    navigator.run()
}
