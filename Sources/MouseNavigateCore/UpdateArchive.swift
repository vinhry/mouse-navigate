import Foundation
import zlib

/// Decides whether a downloaded release archive may be unpacked at all.
///
/// The archive is checked before `ditto` sees it, because `ditto` acts on whatever it is
/// given: a symbolic link to anywhere, a second app beside this one, or a few megabytes
/// that inflate to fill the disk. The signature check that follows can only refuse what
/// has already been written.
///
/// The archive is read here rather than listed with `zipinfo`, because `zipinfo` reads
/// only the contents list at the end of a zip, while `ditto` unpacks the entries at the
/// front one after another and goes by the names and lengths it finds there. An archive
/// whose two halves disagree, or that hides an entry the contents list leaves out, would
/// show `zipinfo` one thing and unpack another; `ditto` also ignores the sizes a zip lists
/// and inflates each entry for as long as its data goes on. So both halves are read and
/// must agree byte for byte, and every entry is inflated, without writing it anywhere, to
/// prove it is no longer than it says. Anything this cannot account for is refused.
public enum UpdateArchive {
    /// The one thing a release archive holds, made by `ditto -c -k --keepParent`.
    public static let appName = "MouseNavigate.app"
    /// A release unpacks to about 6 MB. Sixteen times that leaves room for the app to grow
    /// and none for an archive built to fill the disk.
    public static let maximumUnpackedSize = 100 * 1024 * 1024
    /// A release holds 10 to 20 entries: the app's few files, and on a Mac that tags files
    /// with extended attributes, the `._` file `ditto` stores each one's attributes in.
    public static let maximumEntries = 10_000

    public enum Kind: Equatable, Sendable {
        case directory, file, symbolicLink, other
    }

    public struct Entry: Equatable, Sendable {
        public var path: String
        public var kind: Kind
        /// Bytes once unpacked, as the archive lists it.
        public var size: Int

        public init(path: String, kind: Kind, size: Int) {
            self.path = path
            self.kind = kind
            self.size = size
        }
    }

    public enum Problem: LocalizedError, Equatable, Sendable {
        /// Not a zip this reader can account for; says why, for the log and the alert.
        case unreadable(String)
        case noApp
        case outsideApp(String)
        case symbolicLink(String)
        case special(String)
        case strangeName
        case tooManyEntries(Int)
        case tooLarge(Int)

        public var errorDescription: String? {
            let refused = "so it was not unpacked."
            switch self {
            case .unreadable(let reason):
                return "The download is not an archive MouseNavigate can check (\(reason)), \(refused)"
            case .noApp:
                return "The download does not contain MouseNavigate.app."
            case .outsideApp(let path):
                return "The download holds “\(Problem.shown(path))”, which is outside MouseNavigate.app, \(refused)"
            case .symbolicLink(let path):
                return "The download holds a symbolic link, “\(Problem.shown(path))”, which no MouseNavigate release has, \(refused)"
            case .special(let path):
                return "The download holds “\(Problem.shown(path))”, which is neither a file nor a folder, \(refused)"
            case .strangeName:
                return "The download holds a file whose name has control characters or a backslash, \(refused)"
            case .tooManyEntries(let count):
                return "The download holds \(count) files, far more than any MouseNavigate release, \(refused)"
            case .tooLarge(let bytes):
                let megabytes = (Double(bytes) / 1_048_576).rounded(.up)
                return "The download would unpack to \(Int(megabytes)) MB, far more than any MouseNavigate release, \(refused)"
            }
        }

        /// A name chosen by whoever made the archive, kept short enough for an alert.
        private static func shown(_ path: String) -> String {
            path.count > 80 ? String(path.prefix(80)) + "…" : path
        }
    }

    /// Throws the first reason `archive` may not be unpacked, and otherwise returns what it
    /// holds. Reads the whole archive and inflates every entry, which for a release takes a
    /// few hundredths of a second; never on the main thread.
    @discardableResult
    public static func check(_ archive: Data) throws -> [Entry] {
        let zip = try Zip(archive)
        // The cheap rule first, so nothing a contents list already gives away is inflated.
        try accept(zip.entries)
        try zip.verifyEntryData()
        return zip.entries
    }

    /// The rule on what may be unpacked: only MouseNavigate.app, in files and folders, and
    /// no more of it than any release could be.
    ///
    /// The `._` files `ditto` stores extended attributes in sit beside what they belong to,
    /// so a release's are inside the app and need no rule of their own; a release made with
    /// `--keepParent` has none for the app itself, and no `__MACOSX` folder. Symbolic links
    /// are refused outright, because the app has none: allowing them would mean judging
    /// where each one points, against an archive that may order its entries to write
    /// through a link it made a moment before.
    public static func accept(_ entries: [Entry]) throws {
        guard !entries.isEmpty else { throw Problem.noApp }
        guard entries.count <= maximumEntries else { throw Problem.tooManyEntries(entries.count) }

        for entry in entries {
            // A control character could hide what a name is in the alert that shows it,
            // and some unpackers take a backslash for a folder separator.
            guard !entry.path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0 == "\\" }) else {
                throw Problem.strangeName
            }

            var components = entry.path.split(separator: "/", omittingEmptySubsequences: false)
            if entry.kind == .directory, components.count > 1, components.last == "" {
                components.removeLast()
            }
            // An absolute path starts with an empty component, and the app's own folder is
            // the only thing a release has at the top. Compared byte for byte: Swift's own
            // string comparison treats some different characters as the same.
            func isExactly(_ component: Substring, _ name: String) -> Bool {
                component.utf8.elementsEqual(name.utf8)
            }
            guard let top = components.first, isExactly(top, appName),
                  entry.kind == .directory || components.count > 1,
                  !components.contains(where: { $0.isEmpty || isExactly($0, ".") || isExactly($0, "..") })
            else {
                throw Problem.outsideApp(entry.path)
            }

            switch entry.kind {
            case .directory, .file: break
            case .symbolicLink: throw Problem.symbolicLink(entry.path)
            case .other: throw Problem.special(entry.path)
            }
        }

        // Each size is at most 4 GB and there are at most 10,000 of them, so the sum cannot
        // overflow.
        let total = entries.reduce(0) { $0 + $1.size }
        guard total <= maximumUnpackedSize else { throw Problem.tooLarge(total) }
    }
}

// MARK: - Reading the zip

/// A zip read in full: its contents list, and proof that the entries in front match it.
/// Only what `ditto -c -k` writes is understood: entries stored or deflated, a Unix mode
/// on each, no encryption, no zip64 (which a release is far too small to need), and no
/// archive split across files.
private struct Zip {
    private struct Record {
        var entry: UpdateArchive.Entry
        var nameBytes: Data
        var flags: UInt16
        var method: UInt16
        var crc: UInt32
        var compressedSize: Int
        var localOffset: Int
    }

    private let data: Data
    private let records: [Record]
    /// Where the contents list starts, which is where the last entry's data must end.
    private let directoryOffset: Int

    var entries: [UpdateArchive.Entry] { records.map(\.entry) }

    private static let localSignature: UInt32 = 0x0403_4B50
    private static let centralSignature: UInt32 = 0x0201_4B50
    private static let endSignature: UInt32 = 0x0605_4B50
    private static let zip64LocatorSignature: UInt32 = 0x0706_4B50
    private static let descriptorSignature: UInt32 = 0x0807_4B50

    private static let encryptedFlags: UInt16 = 0x0001 | 0x0040
    private static let descriptorFlag: UInt16 = 0x0008
    private static let stored: UInt16 = 0
    private static let deflated: UInt16 = 8
    private static let unixOrigin: UInt16 = 3

    private static func unreadable(_ reason: String) -> UpdateArchive.Problem {
        .unreadable(reason)
    }

    init(_ data: Data) throws {
        self.data = data

        // The end record is the last 22 bytes, unless a comment follows it.
        let endLength = 22
        guard data.count >= endLength else { throw Zip.unreadable("it is too short to be a zip") }
        var endOffset: Int?
        let earliest = max(0, data.count - endLength - Int(UInt16.max))
        for offset in stride(from: data.count - endLength, through: earliest, by: -1)
        where data.uint32(at: offset) == Zip.endSignature
            && offset + endLength + Int(data.uint16(at: offset + 20)) == data.count {
            endOffset = offset
            break
        }
        guard let end = endOffset else { throw Zip.unreadable("it has no contents list") }
        if end >= 20, data.uint32(at: end - 20) == Zip.zip64LocatorSignature {
            throw Zip.unreadable("it is a zip64 archive")
        }

        let disk = data.uint16(at: end + 4)
        let directoryDisk = data.uint16(at: end + 6)
        let countOnDisk = data.uint16(at: end + 8)
        let count = Int(data.uint16(at: end + 10))
        let directorySize = Int(data.uint32(at: end + 12))
        let directoryOffset = Int(data.uint32(at: end + 16))
        guard disk == 0, directoryDisk == 0, Int(countOnDisk) == count else {
            throw Zip.unreadable("it is split across several files")
        }
        // Nothing may sit between the contents list and its end record, where an
        // unpacker reading from the front could find entries the list does not have.
        guard directoryOffset + directorySize == end else {
            throw Zip.unreadable("its contents list is not where it says")
        }
        self.directoryOffset = directoryOffset

        var records: [Record] = []
        records.reserveCapacity(count)
        var offset = directoryOffset
        for _ in 0..<count {
            let fixed = 46
            guard offset + fixed <= end, data.uint32(at: offset) == Zip.centralSignature else {
                throw Zip.unreadable("its contents list is damaged")
            }
            let madeBy = data.uint16(at: offset + 4)
            let flags = data.uint16(at: offset + 8)
            let method = data.uint16(at: offset + 10)
            let crc = data.uint32(at: offset + 16)
            let compressedSize = data.uint32(at: offset + 20)
            let size = data.uint32(at: offset + 24)
            let nameLength = Int(data.uint16(at: offset + 28))
            let extraLength = Int(data.uint16(at: offset + 30))
            let commentLength = Int(data.uint16(at: offset + 32))
            let startDisk = data.uint16(at: offset + 34)
            let attributes = data.uint32(at: offset + 38)
            let localOffset = data.uint32(at: offset + 42)

            let next = offset + fixed + nameLength + extraLength + commentLength
            guard next <= end else { throw Zip.unreadable("its contents list is damaged") }
            guard compressedSize != .max, size != .max, localOffset != .max, startDisk == 0 else {
                throw Zip.unreadable("it is a zip64 archive")
            }
            guard flags & Zip.encryptedFlags == 0 else { throw Zip.unreadable("an entry is encrypted") }
            guard method == Zip.stored || method == Zip.deflated else {
                throw Zip.unreadable("an entry is compressed in a way it cannot read")
            }
            // The kind of each entry comes from its Unix mode, which only a zip made on a
            // Unix system has.
            guard madeBy >> 8 == Zip.unixOrigin else {
                throw Zip.unreadable("an entry has no Unix file mode")
            }

            let nameBytes = data.bytes((offset + fixed)..<(offset + fixed + nameLength))
            guard let path = String(data: nameBytes, encoding: .utf8), !path.isEmpty else {
                throw Zip.unreadable("a file name is not text")
            }
            let kind: UpdateArchive.Kind
            switch (attributes >> 16) & 0o170000 {
            case 0o040000: kind = .directory
            case 0o100000: kind = .file
            case 0o120000: kind = .symbolicLink
            default: kind = .other
            }
            // A folder is told by its mode and by its name alike; one that says otherwise in
            // either could be unpacked as either.
            guard (kind == .directory) == path.hasSuffix("/") else {
                throw Zip.unreadable("a folder is listed as a file, or a file as a folder")
            }
            guard kind != .directory || (size == 0 && compressedSize == 0) else {
                throw Zip.unreadable("a folder has contents of its own")
            }

            records.append(Record(
                entry: UpdateArchive.Entry(path: path, kind: kind, size: Int(size)),
                nameBytes: nameBytes,
                flags: flags,
                method: method,
                crc: crc,
                compressedSize: Int(compressedSize),
                localOffset: Int(localOffset)
            ))
            offset = next
        }
        guard offset == end else { throw Zip.unreadable("its contents list is damaged") }
        self.records = records
    }

    /// Walks the entries from the front, the way `ditto` does, and requires each to be the
    /// next one in the contents list, under the same name, with data that inflates to
    /// exactly the size listed, until the last one ends where the contents list begins.
    func verifyEntryData() throws {
        let mismatch = Zip.unreadable("an entry is not what its contents list says")
        var offset = 0
        for record in records {
            let fixed = 30
            guard record.localOffset == offset, offset + fixed <= directoryOffset,
                  data.uint32(at: offset) == Zip.localSignature
            else {
                throw Zip.unreadable("it has data its contents list does not account for")
            }
            let flags = data.uint16(at: offset + 6)
            let method = data.uint16(at: offset + 8)
            let crc = data.uint32(at: offset + 14)
            let compressedSize = Int(data.uint32(at: offset + 18))
            let size = Int(data.uint32(at: offset + 22))
            let nameLength = Int(data.uint16(at: offset + 26))
            let extraLength = Int(data.uint16(at: offset + 28))

            let nameStart = offset + fixed
            let dataStart = nameStart + nameLength + extraLength
            let dataEnd = dataStart + record.compressedSize
            guard dataEnd <= directoryOffset else { throw mismatch }
            guard flags == record.flags, method == record.method,
                  data.bytes(nameStart..<(nameStart + nameLength)) == record.nameBytes
            else {
                throw mismatch
            }

            let hasDescriptor = flags & Zip.descriptorFlag != 0
            if hasDescriptor {
                // A stored entry of unknown length cannot be read from the front at all.
                guard method == Zip.deflated || record.compressedSize == 0 else { throw mismatch }
                // The lengths then follow the data, and in front are zero or the same.
                guard (crc == 0 && compressedSize == 0 && size == 0)
                    || (crc == record.crc && compressedSize == record.compressedSize && size == record.entry.size)
                else {
                    throw mismatch
                }
            } else {
                guard crc == record.crc, compressedSize == record.compressedSize, size == record.entry.size else {
                    throw mismatch
                }
            }

            if method == Zip.stored {
                guard record.compressedSize == record.entry.size else { throw mismatch }
            } else {
                try inflatedLength(dataStart..<dataEnd, limit: record.entry.size)
            }

            offset = dataEnd
            if hasDescriptor {
                // An optional signature, then the checksum and both lengths.
                if offset + 4 <= directoryOffset, data.uint32(at: offset) == Zip.descriptorSignature {
                    offset += 4
                }
                guard offset + 12 <= directoryOffset,
                      data.uint32(at: offset) == record.crc,
                      Int(data.uint32(at: offset + 4)) == record.compressedSize,
                      Int(data.uint32(at: offset + 8)) == record.entry.size
                else {
                    throw mismatch
                }
                offset += 12
            }
        }
        guard offset == directoryOffset else {
            throw Zip.unreadable("it has data its contents list does not account for")
        }
    }

    /// Inflates `range` without keeping any of it, and requires the deflated data to end
    /// exactly where the range does and to come to exactly `limit` bytes. Stops as soon as
    /// it passes `limit`, so an entry that lies about its size costs no more than the size
    /// it claimed.
    ///
    /// zlib, not the Compression framework: Compression takes in whatever follows the end
    /// of a deflate stream without saying so, and where the stream ends is the point.
    private func inflatedLength(_ range: Range<Int>, limit: Int) throws {
        let tooLong = Zip.unreadable("an entry unpacks to more than its listed size")
        let damaged = Zip.unreadable("an entry's compressed data is damaged")

        var stream = z_stream()
        // Negative window bits: raw deflate, with no zlib header, which is what a zip holds.
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw damaged
        }
        defer { inflateEnd(&stream) }

        let bufferSize = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { throw damaged }
            // zlib only reads from it.
            stream.next_in = UnsafeMutablePointer(mutating: base + range.lowerBound)
            stream.avail_in = uInt(range.count)

            var produced = 0
            while true {
                stream.next_out = buffer
                stream.avail_out = uInt(bufferSize)
                let status = inflate(&stream, Z_NO_FLUSH)
                produced += bufferSize - Int(stream.avail_out)
                guard produced <= limit else { throw tooLong }

                if status == Z_STREAM_END {
                    // Data left over after the stream ends is where an unpacker reading
                    // from the front would look for the next entry.
                    guard stream.avail_in == 0, produced == limit else { throw damaged }
                    return
                }
                // Anything else, out of input before the end among them, which zlib
                // reports as making no progress.
                guard status == Z_OK else { throw damaged }
            }
        }
    }
}

/// Offsets count from the start of the archive, which for a slice of a larger Data is not
/// index zero. Little-endian, as everything in a zip is. Callers check the bounds first.
private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let at = startIndex + offset
        return UInt16(self[at]) | UInt16(self[at + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        let at = startIndex + offset
        return UInt32(self[at]) | UInt32(self[at + 1]) << 8
            | UInt32(self[at + 2]) << 16 | UInt32(self[at + 3]) << 24
    }

    func bytes(_ range: Range<Int>) -> Data {
        subdata(in: (startIndex + range.lowerBound)..<(startIndex + range.upperBound))
    }
}
