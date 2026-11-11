import Compression
import XCTest
@testable import MouseNavigateCore

final class UpdateArchiveRuleTests: XCTestCase {
    typealias Entry = UpdateArchive.Entry

    private func dir(_ path: String) -> Entry { Entry(path: path, kind: .directory, size: 0) }
    private func file(_ path: String, _ size: Int = 10) -> Entry { Entry(path: path, kind: .file, size: size) }

    private func problem(_ entries: [Entry]) -> UpdateArchive.Problem? {
        do {
            try UpdateArchive.accept(entries)
            return nil
        } catch {
            return error as? UpdateArchive.Problem
        }
    }

    /// The published v0.8.0 MouseNavigate.zip, as built, stapled and zipped by the release
    /// workflow: the stapled ticket in Contents/CodeResources, and nothing else around it.
    static let publishedRelease: [Entry] = [
        Entry(path: "MouseNavigate.app/", kind: .directory, size: 0),
        Entry(path: "MouseNavigate.app/Contents/", kind: .directory, size: 0),
        Entry(path: "MouseNavigate.app/Contents/CodeResources", kind: .file, size: 1674),
        Entry(path: "MouseNavigate.app/Contents/_CodeSignature/", kind: .directory, size: 0),
        Entry(path: "MouseNavigate.app/Contents/_CodeSignature/CodeResources", kind: .file, size: 2446),
        Entry(path: "MouseNavigate.app/Contents/MacOS/", kind: .directory, size: 0),
        Entry(path: "MouseNavigate.app/Contents/MacOS/MouseNavigate", kind: .file, size: 5_540_400),
        Entry(path: "MouseNavigate.app/Contents/Resources/", kind: .directory, size: 0),
        Entry(path: "MouseNavigate.app/Contents/Resources/AppIcon.icns", kind: .file, size: 269_005),
        Entry(path: "MouseNavigate.app/Contents/Info.plist", kind: .file, size: 1011),
    ]

    /// `scripts/build-app.sh` on a Mac that tags new files with com.apple.provenance: ditto
    /// stores each file's and folder's attributes in a `._` file beside it.
    static let localBuild: [Entry] = [
        Entry(path: "MouseNavigate.app/", kind: .directory, size: 0),
        Entry(path: "MouseNavigate.app/Contents/", kind: .directory, size: 0),
        Entry(path: "MouseNavigate.app/Contents/_CodeSignature/", kind: .directory, size: 0),
        Entry(path: "MouseNavigate.app/Contents/_CodeSignature/CodeResources", kind: .file, size: 2446),
        Entry(path: "MouseNavigate.app/Contents/_CodeSignature/._CodeResources", kind: .file, size: 163),
        Entry(path: "MouseNavigate.app/Contents/.__CodeSignature", kind: .file, size: 163),
        Entry(path: "MouseNavigate.app/Contents/MacOS/", kind: .directory, size: 0),
        Entry(path: "MouseNavigate.app/Contents/MacOS/MouseNavigate", kind: .file, size: 5_694_928),
        Entry(path: "MouseNavigate.app/Contents/MacOS/._MouseNavigate", kind: .file, size: 163),
        Entry(path: "MouseNavigate.app/Contents/._MacOS", kind: .file, size: 163),
        Entry(path: "MouseNavigate.app/Contents/Resources/", kind: .directory, size: 0),
        Entry(path: "MouseNavigate.app/Contents/Resources/AppIcon.icns", kind: .file, size: 269_005),
        Entry(path: "MouseNavigate.app/Contents/Resources/._AppIcon.icns", kind: .file, size: 163),
        Entry(path: "MouseNavigate.app/Contents/._Resources", kind: .file, size: 163),
        Entry(path: "MouseNavigate.app/Contents/Info.plist", kind: .file, size: 1011),
        Entry(path: "MouseNavigate.app/Contents/._Info.plist", kind: .file, size: 163),
        Entry(path: "MouseNavigate.app/._Contents", kind: .file, size: 163),
    ]

    func testRealReleasesAreAccepted() {
        XCTAssertNil(problem(Self.publishedRelease))
        XCTAssertNil(problem(Self.localBuild))
    }

    func testTraversalIsRefused() {
        XCTAssertEqual(
            problem([dir("MouseNavigate.app/"), file("MouseNavigate.app/../escaped")]),
            .outsideApp("MouseNavigate.app/../escaped")
        )
        XCTAssertEqual(problem([file("../MouseNavigate.app/x")]), .outsideApp("../MouseNavigate.app/x"))
        XCTAssertEqual(problem([file("MouseNavigate.app/Contents/./x")]), .outsideApp("MouseNavigate.app/Contents/./x"))
        XCTAssertEqual(problem([file("MouseNavigate.app//x")]), .outsideApp("MouseNavigate.app//x"))
    }

    func testAbsolutePathsAreRefused() {
        XCTAssertEqual(problem([file("/MouseNavigate.app/x")]), .outsideApp("/MouseNavigate.app/x"))
        XCTAssertEqual(problem([file("/Users/me/Library/LaunchAgents/x.plist")]), .outsideApp("/Users/me/Library/LaunchAgents/x.plist"))
    }

    func testSymbolicLinksAreRefusedWhereverTheyPoint() {
        let link = Entry(path: "MouseNavigate.app/Contents/Frameworks", kind: .symbolicLink, size: 8)
        XCTAssertEqual(problem(Self.publishedRelease + [link]), .symbolicLink(link.path))
    }

    func testOnlyFilesAndFolders() {
        let fifo = Entry(path: "MouseNavigate.app/pipe", kind: .other, size: 0)
        XCTAssertEqual(problem([dir("MouseNavigate.app/"), fifo]), .special("MouseNavigate.app/pipe"))
    }

    func testNothingBesideTheApp() {
        XCTAssertEqual(problem(Self.publishedRelease + [dir("Other.app/")]), .outsideApp("Other.app/"))
        XCTAssertEqual(problem(Self.publishedRelease + [file("README")]), .outsideApp("README"))
        // Spelled another way, which a case-insensitive disk would merge with the app.
        XCTAssertEqual(problem([file("mousenavigate.app/x")]), .outsideApp("mousenavigate.app/x"))
        // What ditto would add without --keepParent or with --sequesterRsrc; a release has
        // neither.
        XCTAssertEqual(problem(Self.publishedRelease + [file("._MouseNavigate.app")]), .outsideApp("._MouseNavigate.app"))
        XCTAssertEqual(
            problem(Self.publishedRelease + [file("__MACOSX/MouseNavigate.app/._Contents")]),
            .outsideApp("__MACOSX/MouseNavigate.app/._Contents")
        )
    }

    func testTheAppIsAFolder() {
        XCTAssertEqual(problem([file("MouseNavigate.app")]), .outsideApp("MouseNavigate.app"))
        XCTAssertNil(problem([dir("MouseNavigate.app/")]))
    }

    func testNamesWithControlCharactersOrBackslashes() {
        XCTAssertEqual(problem([file("MouseNavigate.app/a\nb")]), .strangeName)
        XCTAssertEqual(problem([file("MouseNavigate.app/a\u{7F}")]), .strangeName)
        XCTAssertEqual(problem([file("MouseNavigate.app\\..\\..\\x")]), .strangeName)
        XCTAssertNil(problem([file("MouseNavigate.app/Contents/Resources/en.lproj/Localizable strings")]))
    }

    func testEmptyArchive() {
        XCTAssertEqual(problem([]), .noApp)
    }

    func testOversizeIsRefused() {
        let limit = UpdateArchive.maximumUnpackedSize
        XCTAssertNil(problem([dir("MouseNavigate.app/"), file("MouseNavigate.app/a", limit)]))
        XCTAssertEqual(
            problem([dir("MouseNavigate.app/"), file("MouseNavigate.app/a", limit), file("MouseNavigate.app/b", 1)]),
            .tooLarge(limit + 1)
        )
        // Many entries at the most a zip can list each, which must not overflow the sum.
        let huge = (0..<1000).map { file("MouseNavigate.app/\($0)", Int(UInt32.max)) }
        XCTAssertEqual(problem(huge), .tooLarge(1000 * Int(UInt32.max)))
    }

    func testTooManyEntries() {
        let many = (0...UpdateArchive.maximumEntries).map { file("MouseNavigate.app/\($0)", 0) }
        XCTAssertEqual(problem(many), .tooManyEntries(UpdateArchive.maximumEntries + 1))
    }

    func testMessages() {
        XCTAssertEqual(
            UpdateArchive.Problem.outsideApp("../x").localizedDescription,
            "The download holds “../x”, which is outside MouseNavigate.app, so it was not unpacked."
        )
        XCTAssertEqual(
            UpdateArchive.Problem.tooLarge(150 * 1024 * 1024).localizedDescription,
            "The download would unpack to 150 MB, far more than any MouseNavigate release, so it was not unpacked."
        )
        let long = "MouseNavigate.app/" + String(repeating: "a", count: 200)
        XCTAssertTrue(UpdateArchive.Problem.symbolicLink(long).localizedDescription.contains(String(long.prefix(80)) + "…”"))
    }
}

// MARK: - Reading archives

/// One entry of a zip made by hand, with the ways a hostile one could differ from what
/// ditto writes.
private struct ZipItem {
    var name: String
    var mode: UInt32 = 0o100644
    var content = Data()
    var deflated = false
    /// Lengths after the data instead of in front, as ditto writes files.
    var descriptor = false
    /// Unix, zip 2.1.
    var madeBy: UInt16 = 0x0315
    var flags: UInt16 = 0
    /// What the headers claim it unpacks to, if not the truth.
    var listedSize: Int?
    /// The name in front, if not the one in the contents list.
    var localName: String?
    /// false: in front only, left out of the contents list.
    var listed = true
    /// Bytes after the compressed data, counted in its length.
    var trailing = Data()

    static func dir(_ name: String) -> ZipItem { ZipItem(name: name, mode: 0o040755) }
    static func file(_ name: String, _ text: String = "contents", deflated: Bool = true) -> ZipItem {
        ZipItem(name: name, content: Data(text.utf8), deflated: deflated, descriptor: deflated)
    }
}

private func le16(_ value: Int) -> Data { le16(UInt16(value)) }
private func le16(_ value: UInt16) -> Data { Data([UInt8(value & 0xFF), UInt8(value >> 8)]) }
private func le32(_ value: Int) -> Data { le32(UInt32(value)) }
private func le32(_ value: UInt32) -> Data {
    Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
}

private func deflate(_ data: Data) -> Data {
    let capacity = data.count + 1024
    var out = Data(count: capacity)
    let count = out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) in
            compression_encode_buffer(
                dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                nil, COMPRESSION_ZLIB
            )
        }
    }
    return out.prefix(count)
}

private func makeZip(_ items: [ZipItem], comment: Data = Data()) -> Data {
    var out = Data()
    var central = Data()
    var count = 0
    for item in items {
        let payload = (item.deflated ? deflate(item.content) : item.content) + item.trailing
        let size = item.listedSize ?? item.content.count
        let crc = 0x1234_5678
        let flags = item.flags | (item.descriptor ? 0x0008 : 0)
        let method = item.deflated ? 8 : 0
        let name = Data(item.name.utf8)
        let localName = Data((item.localName ?? item.name).utf8)
        let offset = out.count

        out += le32(0x0403_4B50) + le16(20) + le16(flags) + le16(method) + le16(0) + le16(0)
        out += item.descriptor ? le32(0) + le32(0) + le32(0) : le32(crc) + le32(payload.count) + le32(size)
        out += le16(localName.count) + le16(0) + localName + payload
        if item.descriptor {
            out += le32(0x0807_4B50) + le32(crc) + le32(payload.count) + le32(size)
        }
        if item.listed {
            central += le32(0x0201_4B50) + le16(item.madeBy) + le16(20) + le16(flags) + le16(method)
            central += le16(0) + le16(0) + le32(crc) + le32(payload.count) + le32(size)
            central += le16(name.count) + le16(0) + le16(0) + le16(0) + le16(0)
            central += le32(item.mode << 16) + le32(offset) + name
            count += 1
        }
    }
    let directoryOffset = out.count
    out += central
    out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(count) + le16(count)
    out += le32(central.count) + le32(directoryOffset) + le16(comment.count) + comment
    return out
}

final class UpdateArchiveReaderTests: XCTestCase {
    private let app: [ZipItem] = [
        .dir("MouseNavigate.app/"),
        .dir("MouseNavigate.app/Contents/"),
        .file("MouseNavigate.app/Contents/Info.plist", "<plist/>"),
        .file("MouseNavigate.app/Contents/MacOS/MouseNavigate", String(repeating: "binary ", count: 5000)),
        .file("MouseNavigate.app/Contents/PkgInfo", "APPL????", deflated: false),
    ]

    private func problem(_ archive: Data) -> UpdateArchive.Problem? {
        do {
            try UpdateArchive.check(archive)
            return nil
        } catch {
            return error as? UpdateArchive.Problem
        }
    }

    private func isUnreadable(_ archive: Data, file: StaticString = #filePath, line: UInt = #line) {
        guard case .unreadable? = problem(archive) else {
            return XCTFail("expected unreadable, got \(String(describing: problem(archive)))", file: file, line: line)
        }
    }

    func testAWellFormedArchiveIsReadInFull() throws {
        let entries = try UpdateArchive.check(makeZip(app))
        XCTAssertEqual(entries.map(\.path), app.map(\.name))
        XCTAssertEqual(entries[3], .init(path: "MouseNavigate.app/Contents/MacOS/MouseNavigate", kind: .file, size: 35_000))
        XCTAssertEqual(entries[0].kind, .directory)
    }

    func testASliceOfALargerBufferReadsTheSame() throws {
        let archive = makeZip(app)
        let padded = Data([1, 2, 3]) + archive
        let slice = padded[padded.startIndex + 3..<padded.endIndex]
        XCTAssertEqual(try UpdateArchive.check(slice).count, app.count)
    }

    func testACommentAfterTheContentsListIsAllowed() {
        XCTAssertNil(problem(makeZip(app, comment: Data("made by hand".utf8))))
    }

    func testTheRuleIsAppliedToWhatIsRead() {
        XCTAssertEqual(problem(makeZip(app + [.file("MouseNavigate.app/../x")])), .outsideApp("MouseNavigate.app/../x"))
        XCTAssertEqual(problem(makeZip(app + [.file("Other.app/x")])), .outsideApp("Other.app/x"))
        var link = ZipItem.file("MouseNavigate.app/Contents/link", "/etc", deflated: false)
        link.mode = 0o120755
        XCTAssertEqual(problem(makeZip(app + [link])), .symbolicLink("MouseNavigate.app/Contents/link"))
    }

    /// ditto unpacks what it finds in front, so an entry the contents list leaves out
    /// would be unpacked unchecked.
    func testAnEntryHiddenFromTheContentsListIsRefused() {
        var hidden = ZipItem.file("../../Library/LaunchAgents/evil.plist")
        hidden.listed = false
        isUnreadable(makeZip([app[0], hidden] + app.dropFirst()))
        isUnreadable(makeZip(app + [hidden]))
    }

    /// ditto goes by the name in front, not the one in the contents list.
    func testANameThatDiffersInFrontIsRefused() {
        var renamed = ZipItem.file("MouseNavigate.app/Contents/aaaaaaaa")
        renamed.localName = "Other.app/bbbbbbbbbbbbbbbbbbbbbbbb"
        isUnreadable(makeZip(app + [renamed]))
    }

    /// ditto inflates each entry to the end of its data, whatever size the zip lists.
    func testAnEntryThatInflatesBeyondItsListedSizeIsRefused() {
        var bomb = ZipItem.file("MouseNavigate.app/Contents/big", String(repeating: "\0", count: 1_000_000))
        bomb.listedSize = 10
        isUnreadable(makeZip(app + [bomb]))

        var short = ZipItem.file("MouseNavigate.app/Contents/short", String(repeating: "x", count: 1000))
        short.listedSize = 2000
        isUnreadable(makeZip(app + [short]))
    }

    func testAStoredEntryMustBeItsListedSize() {
        var stored = ZipItem.file("MouseNavigate.app/Contents/stored", "twelve bytes", deflated: false)
        stored.listedSize = 11
        isUnreadable(makeZip(app + [stored]))
    }

    /// Data after the end of a deflate stream is where an unpacker reading from the front
    /// would look for the next entry.
    func testDataAfterTheDeflateStreamIsRefused() {
        var padded = ZipItem.file("MouseNavigate.app/Contents/padded")
        padded.trailing = Data("PK\u{3}\u{4}".utf8)
        isUnreadable(makeZip(app + [padded]))
    }

    func testDamagedDeflateDataIsRefused() {
        var damaged = ZipItem.file("MouseNavigate.app/Contents/damaged", deflated: false)
        damaged.deflated = true
        damaged.descriptor = true
        let archive = makeZip(app + [damaged])
        // Overwrite the start of its compressed data with an invalid block type.
        var bytes = archive
        let marker = Data("MouseNavigate.app/Contents/damaged".utf8)
        let at = bytes.range(of: marker)!.upperBound
        bytes[at] = 0xFF
        isUnreadable(bytes)
    }

    func testDataBeforeTheFirstEntryIsRefused() {
        isUnreadable(Data("#!/bin/sh\n".utf8) + makeZip(app))
    }

    func testDataBetweenEntriesIsRefused() {
        let archive = makeZip(app)
        // Move every entry back by inserting bytes after the first; offsets no longer meet.
        let first = makeZip([app[0]])
        let firstLength = first.count - 46 - app[0].name.utf8.count - 22
        var bytes = archive
        bytes.insert(contentsOf: [0, 0, 0, 0], at: firstLength)
        isUnreadable(bytes)
    }

    func testOnlyWhatDittoWritesIsUnderstood() {
        var encrypted = ZipItem.file("MouseNavigate.app/Contents/secret")
        encrypted.flags = 0x0001
        isUnreadable(makeZip(app + [encrypted]))

        var dos = ZipItem.file("MouseNavigate.app/Contents/dos")
        dos.madeBy = 0x0014
        isUnreadable(makeZip(app + [dos]))

        // A folder must say so in its name and its mode alike.
        var odd = ZipItem.dir("MouseNavigate.app/Resources")
        odd.mode = 0o040755
        isUnreadable(makeZip(app + [odd]))
        var fileAsFolder = ZipItem.file("MouseNavigate.app/Resources/", deflated: false)
        fileAsFolder.content = Data()
        isUnreadable(makeZip(app + [fileAsFolder]))
    }

    func testAZip64ArchiveIsRefused() {
        var archive = makeZip(app)
        let end = archive.count - 22
        let locator = le32(0x0706_4B50) + le32(0) + Data(count: 8) + le32(1)
        archive.insert(contentsOf: locator, at: end)
        isUnreadable(archive)
    }

    func testTruncatedOrEmpty() {
        isUnreadable(Data())
        isUnreadable(Data("not a zip at all".utf8))
        let archive = makeZip(app)
        isUnreadable(archive.prefix(archive.count - 1))
        isUnreadable(archive.prefix(archive.count / 2))
        XCTAssertEqual(problem(makeZip([])), .noApp)
    }
}

/// Archives made by ditto itself, the way the release workflow makes them, so the reader is
/// known to understand what a real release holds. Run in a temporary folder.
final class UpdateArchiveDittoTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/ditto"))
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UpdateArchiveDittoTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    /// A small app shaped like the real one, with an extended attribute on each file and
    /// folder, so ditto writes `._` entries as it does for a local build.
    private func makeApp(in folder: URL, name: String = "MouseNavigate.app") throws -> URL {
        let app = folder.appendingPathComponent(name, isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let files = [
            contents.appendingPathComponent("Info.plist"),
            macOS.appendingPathComponent("MouseNavigate"),
        ]
        try Data("<plist/>".utf8).write(to: files[0])
        try Data(repeating: 0xCF, count: 300_000).write(to: files[1])
        for url in files + [contents, macOS] {
            let value = Data("tagged".utf8)
            let status = value.withUnsafeBytes {
                setxattr(url.path, "com.example.test", $0.baseAddress, value.count, 0, 0)
            }
            XCTAssertEqual(status, 0)
        }
        return app
    }

    private func ditto(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }

    private func check(_ zip: URL) throws -> [UpdateArchive.Entry] {
        try UpdateArchive.check(Data(contentsOf: zip, options: .alwaysMapped))
    }

    func testAReleaseMadeTheWayTheWorkflowDoesIsAccepted() throws {
        let app = try makeApp(in: root.appendingPathComponent("build"))
        let zip = root.appendingPathComponent("MouseNavigate.zip")
        try ditto(["-c", "-k", "--keepParent", app.path, zip.path])

        let entries = try check(zip)
        XCTAssertTrue(entries.contains { $0.path == "MouseNavigate.app/Contents/MacOS/MouseNavigate" && $0.size == 300_000 })
        XCTAssertTrue(entries.contains { $0.path.hasSuffix("/._Info.plist") }, "ditto stored the attributes beside the file")
    }

    func testALinkInsideTheAppIsRefused() throws {
        let app = try makeApp(in: root.appendingPathComponent("build"))
        try FileManager.default.createSymbolicLink(
            atPath: app.appendingPathComponent("Contents/Up").path,
            withDestinationPath: "../.."
        )
        let zip = root.appendingPathComponent("MouseNavigate.zip")
        try ditto(["-c", "-k", "--keepParent", app.path, zip.path])

        XCTAssertThrowsError(try check(zip)) { error in
            XCTAssertEqual(error as? UpdateArchive.Problem, .symbolicLink("MouseNavigate.app/Contents/Up"))
        }
    }

    func testASecondAppBesideItIsRefused() throws {
        let folder = root.appendingPathComponent("build")
        _ = try makeApp(in: folder)
        _ = try makeApp(in: folder, name: "Other.app")
        let zip = root.appendingPathComponent("MouseNavigate.zip")
        try ditto(["-c", "-k", folder.path, zip.path])

        XCTAssertThrowsError(try check(zip)) { error in
            guard case .outsideApp? = error as? UpdateArchive.Problem else {
                return XCTFail("expected outsideApp, got \(error)")
            }
        }
    }
}
