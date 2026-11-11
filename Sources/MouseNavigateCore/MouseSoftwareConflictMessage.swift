import Foundation

/// The warning shown on the Mouse tab while other mouse software is running.
public enum MouseSoftwareConflictMessage {
    /// Names the software and says what to do about it, worded for one or several; nil when
    /// none is running.
    public static func text(for names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let list = TrackpadConflictMessage.list(names)
        if names.count == 1 {
            return "\(list) is also running. It can change what the same buttons do, so a button may "
                + "act twice or not at all. Quit it, or turn off its button actions for this mouse."
        }
        return "\(list) are also running. They can change what the same buttons do, so a button may "
            + "act twice or not at all. Quit them, or turn off their button actions for this mouse."
    }
}
