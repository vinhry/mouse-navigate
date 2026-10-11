import Foundation

/// Runs a command-line tool to the end, or until it has had long enough.
///
/// A tool waited on with no limit can hold its caller for good. An update whose `ditto` or
/// `spctl` never returned stayed "downloading" for the rest of the session, and every later
/// check was refused as already under way. Blocks until the tool is done, so never on the
/// main thread.
enum ProcessRunner {
    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    struct Result {
        var status: Int32
        /// Standard output and error together, when asked for.
        var output: String
    }

    /// How long a tool asked to stop is given before it is killed.
    private static let terminationGrace: TimeInterval = 2

    /// Throws when the tool cannot be started or is still running after `timeout` seconds,
    /// in which case it is stopped. A tool that runs and fails is not an error here: its
    /// status is returned for the caller to judge.
    static func run(
        _ tool: String,
        _ arguments: [String],
        timeout: TimeInterval,
        capturingOutput: Bool = false
    ) throws -> Result {
        let name = (tool as NSString).lastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        // Read as it arrives, on another thread: a tool that fills the pipe's buffer would
        // otherwise wait for a reader that is waiting for it to exit.
        var output = Data()
        let drained = DispatchSemaphore(value: 0)
        if capturingOutput {
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            let reader = pipe.fileHandleForReading
            DispatchQueue.global(qos: .utility).async {
                output = reader.readDataToEndOfFile()
                drained.signal()
            }
        } else {
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            drained.signal()
        }

        do {
            try process.run()
        } catch {
            throw Failure(errorDescription: "\(name) could not be started: \(error.localizedDescription)")
        }

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if exited.wait(timeout: .now() + terminationGrace) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + terminationGrace)
            }
            throw Failure(errorDescription: "\(name) took longer than \(Int(timeout)) seconds and was stopped.")
        }

        // The pipe closes when the tool exits, unless something it started still holds it,
        // in which case the output is given up on rather than read while still arriving.
        let isDrained = drained.wait(timeout: .now() + terminationGrace) == .success
        return Result(
            status: process.terminationStatus,
            output: isDrained ? String(decoding: output, as: UTF8.self) : ""
        )
    }
}
