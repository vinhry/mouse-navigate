import Foundation

/// A property-list value as a settings file carries it: the subset JSON and UserDefaults
/// both hold.
public enum SettingsValue: Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    indirect case dictionary([String: SettingsValue])

    /// Reads a value the registry says is of `type`. Numbers are the catch: JSON and
    /// property lists both hand back an `NSNumber` for `1`, `1.5` and `true`, and only
    /// the registry knows which was meant. A bool must be a real boolean, an int a whole
    /// number, and a double any number but a boolean.
    public init?(any value: Any, as type: SettingsKey.ValueType) {
        switch type {
        case .bool:
            guard SettingsValue.isBoolean(value), let bool = value as? Bool else { return nil }
            self = .bool(bool)
        case .int:
            guard !SettingsValue.isBoolean(value), let number = value as? NSNumber,
                  let int = Int(exactly: number.doubleValue)
            else { return nil }
            self = .int(int)
        case .double:
            guard !SettingsValue.isBoolean(value), let number = value as? NSNumber else { return nil }
            self = .double(number.doubleValue)
        case .string:
            guard let string = value as? String else { return nil }
            self = .string(string)
        case .dictionary:
            guard let dictionary = value as? [String: Any] else { return nil }
            var entries: [String: SettingsValue] = [:]
            for (key, entry) in dictionary {
                guard let converted = SettingsValue(any: entry) else { return nil }
                entries[key] = converted
            }
            self = .dictionary(entries)
        case .date:
            return nil
        }
    }

    /// Reads a value nothing describes, as inside a dictionary: the value's own kind
    /// decides, and arrays and dates are not carried.
    public init?(any value: Any) {
        if SettingsValue.isBoolean(value), let bool = value as? Bool {
            self = .bool(bool)
        } else if let number = value as? NSNumber {
            if !SettingsValue.isFloat(number), let int = Int(exactly: number.doubleValue) {
                self = .int(int)
            } else {
                self = .double(number.doubleValue)
            }
        } else if let string = value as? String {
            self = .string(string)
        } else if let dictionary = value as? [String: Any] {
            guard let converted = SettingsValue(any: dictionary, as: .dictionary) else { return nil }
            self = converted
        } else {
            return nil
        }
    }

    /// The value as `UserDefaults` and `JSONSerialization` take it.
    public var any: Any {
        switch self {
        case .bool(let bool): return bool
        case .int(let int): return int
        case .double(let double): return double
        case .string(let string): return string
        case .dictionary(let entries): return entries.mapValues(\.any)
        }
    }

    private static func isBoolean(_ value: Any) -> Bool {
        CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID()
    }

    private static func isFloat(_ number: NSNumber) -> Bool {
        CFNumberIsFloatType(number)
    }
}

/// Every setting, as written to and read back from a file.
///
/// The file is JSON, pretty-printed with its keys sorted so two exports can be compared.
/// Bindings appear exactly as they are stored: a built-in action by name, a custom one as
/// the small JSON object it already is, so the file can be read and edited by hand.
public struct SettingsSnapshot: Equatable {
    public static let format = "MouseNavigate settings"
    /// The file's own layout, not the settings'. Bumped only if the envelope changes.
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// The settings' layout, as `Preferences` migrates it.
    public var configVersion: Int
    public var appVersion: String?
    public var values: [String: SettingsValue]

    public init(schemaVersion: Int = currentSchemaVersion, configVersion: Int, appVersion: String?, values: [String: SettingsValue]) {
        self.schemaVersion = schemaVersion
        self.configVersion = configVersion
        self.appVersion = appVersion
        self.values = values
    }

    public enum ReadError: Error, Equatable {
        case notASettingsFile
        case unsupportedSchema(Int)
        /// Written by a newer MouseNavigate whose settings this one cannot read.
        case newerConfigVersion(Int)
        case wrongType(key: String, expected: SettingsKey.ValueType)
    }

    public struct ReadResult: Equatable {
        public var snapshot: SettingsSnapshot
        /// Keys the file had that MouseNavigate does not know, left where they were.
        public var ignoredKeys: [String]
    }

    // MARK: - Capturing

    /// Everything exportable that `store` holds.
    public static func capture(from store: UserDefaults, configVersion: Int, appVersion: String?) -> SettingsSnapshot {
        var values: [String: SettingsValue] = [:]
        for key in SettingsKey.userSettingKeys(in: store)
        where SettingsKey.isExportable(key) && key != SettingsKey.configVersion {
            guard let type = SettingsKey.type(of: key), let raw = store.object(forKey: key),
                  let value = SettingsValue(any: raw, as: type)
            else { continue }
            values[key] = value
        }
        return SettingsSnapshot(configVersion: configVersion, appVersion: appVersion, values: values)
    }

    public func jsonData() throws -> Data {
        var envelope: [String: Any] = [
            "format": SettingsSnapshot.format,
            "schemaVersion": schemaVersion,
            "configVersion": configVersion,
            "settings": values.mapValues(\.any),
        ]
        if let appVersion {
            envelope["appVersion"] = appVersion
        }
        return try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Reading

    /// Checks the file before anything is written: a key of the wrong type refuses the
    /// whole file rather than importing part of it. Unknown keys are ignored and named.
    /// An older layout is accepted, since the migration that follows knows it; a newer
    /// one is not.
    public static func read(_ data: Data, currentConfigVersion: Int) throws -> ReadResult {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let envelope = object as? [String: Any],
              envelope["format"] as? String == format,
              let settings = envelope["settings"] as? [String: Any]
        else {
            throw ReadError.notASettingsFile
        }
        let schemaVersion = (envelope["schemaVersion"] as? NSNumber)?.intValue ?? 0
        guard schemaVersion == currentSchemaVersion else {
            throw ReadError.unsupportedSchema(schemaVersion)
        }
        let configVersion = (envelope["configVersion"] as? NSNumber)?.intValue ?? 0
        guard configVersion <= currentConfigVersion else {
            throw ReadError.newerConfigVersion(configVersion)
        }

        var values: [String: SettingsValue] = [:]
        var ignored: [String] = []
        for (key, raw) in settings {
            guard key != SettingsKey.configVersion, let type = SettingsKey.type(of: key), type != .date else {
                ignored.append(key)
                continue
            }
            guard let value = SettingsValue(any: raw, as: type) else {
                throw ReadError.wrongType(key: key, expected: type)
            }
            if key == SettingsKey.appOverrides, !appOverridesAreWellFormed(value) {
                throw ReadError.wrongType(key: key, expected: type)
            }
            values[key] = value
        }

        let snapshot = SettingsSnapshot(
            schemaVersion: schemaVersion,
            configVersion: configVersion,
            appVersion: envelope["appVersion"] as? String,
            values: values
        )
        return ReadResult(snapshot: snapshot, ignoredKeys: ignored.sorted())
    }

    /// Every entry must read back as an app override, since one that did not would be
    /// dropped silently on the next save.
    private static func appOverridesAreWellFormed(_ value: SettingsValue) -> Bool {
        guard case .dictionary(let entries) = value else { return false }
        return entries.allSatisfy { AppOverride(bundleID: $0.key, propertyList: $0.value.any) != nil }
    }

    // MARK: - Applying

    /// Replaces every setting in `store` with the snapshot's. Keys the snapshot lacks are
    /// removed, so the result is the file and nothing else; the caller migrates after.
    public func apply(to store: UserDefaults) {
        for key in SettingsKey.userSettingKeys(in: store) where !SettingsKey.bookkeeping.contains(key) {
            store.removeObject(forKey: key)
        }
        for (key, value) in values {
            store.set(value.any, forKey: key)
        }
        store.set(configVersion, forKey: SettingsKey.configVersion)
    }
}
