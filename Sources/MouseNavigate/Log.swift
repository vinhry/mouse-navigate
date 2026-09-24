import Foundation
import os

/// Startup and permission events go to the unified log.
///
/// A menu bar app that fails on someone else's Mac has no window and no terminal to
/// explain itself with, and printing to stdout reaches nobody when the app was launched
/// from Finder. Asking for one command is the most that can be expected of anyone:
///
///     log show --last 10m --predicate 'subsystem == "com.vinhry.MouseNavigate"' --info
///
/// so anything needed to work out why the app is not doing its job belongs here. Paths and
/// versions are marked public: this log is a support aid, and redacted lines are useless.
enum Log {
    private static let subsystem = "com.vinhry.MouseNavigate"

    /// Becoming an application, claiming the instance, putting the icon up.
    static let launch = Logger(subsystem: subsystem, category: "launch")
    /// Accessibility and Input Monitoring, which is where a new install usually stalls.
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
}
