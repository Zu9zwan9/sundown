import Foundation

/// A deliberately small process runner.
///
/// No shell interpretation, absolute paths only, hard timeout. Everything we
/// shell out for is a read (`lsof`, `docker ps`) or a documented stop
/// (`docker stop`) — nothing is ever interpolated from user input.
enum Shell {

    struct Result {
        let status: Int32
        let output: String
    }

    /// Returns `nil` when the executable is absent — the caller treats that as
    /// "this capability isn't installed here" and stays quiet about it.
    static func run(
        _ executable: String,
        _ arguments: [String],
        timeout: TimeInterval = 4
    ) -> Result? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return nil }

        // Read on a background queue so a large result can't deadlock the pipe.
        var data = Data()
        let lock = NSLock()
        let reader = DispatchQueue(label: "sundown.shell.read")
        reader.async {
            let chunk = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); data = chunk; lock.unlock()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if task.isRunning {
            task.terminate()
            return nil
        }
        reader.sync {}

        lock.lock()
        let output = String(decoding: data, as: UTF8.self)
        lock.unlock()

        return Result(status: task.terminationStatus, output: output)
    }

    /// First path that exists, for tools that move around between Intel,
    /// Apple silicon, and Docker Desktop installs.
    static func locate(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
