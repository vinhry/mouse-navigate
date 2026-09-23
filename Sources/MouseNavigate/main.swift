import Foundation

let navigator = MouseNavigator()
navigator.isTouchDebugEnabled = CommandLine.arguments.contains("--touch-debug")
let isAppBundleLaunch = Bundle.main.bundleURL.pathExtension == "app"
let forceDaemon = CommandLine.arguments.contains("--daemon")

if CommandLine.arguments.contains("--list-devices") {
    // Support aid: shows what the detector sees without needing any permissions.
    navigator.printDetectedDevices()
} else if forceDaemon || !isAppBundleLaunch {
    navigator.runDaemon()
} else {
    navigator.runLauncher()
}
