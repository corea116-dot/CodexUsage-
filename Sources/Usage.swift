import Foundation
import Darwin

enum UsageError: Error, LocalizedError {
    case cliMissing, connection, timeout, invalidResponse, noWeeklyLimit

    var errorDescription: String? {
        switch self {
        case .cliMissing: return "Codex 실행 파일을 찾을 수 없습니다."
        case .connection: return "Codex 사용량에 연결할 수 없습니다."
        case .timeout: return "사용량 조회 시간이 초과되었습니다."
        case .invalidResponse: return "사용량 응답을 읽을 수 없습니다."
        case .noWeeklyLimit: return "Codex 주간 한도를 확인할 수 없습니다."
        }
    }
}

struct UsageSnapshot: Equatable {
    let remainingPercent: Int

    static func parse(_ data: Data) throws -> UsageSnapshot {
        struct Window: Decodable {
            let usedPercent: Double
            let windowDurationMins: Int?
        }
        struct Bucket: Decodable {
            let limitId: String?
            let primary: Window?
            let secondary: Window?
        }
        struct Response: Decodable {
            let rateLimits: Bucket?
            let rateLimitsByLimitId: [String: Bucket]?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        let bucket: Bucket
        if let buckets = response.rateLimitsByLimitId, !buckets.isEmpty {
            guard let codex = buckets["codex"] else { throw UsageError.noWeeklyLimit }
            bucket = codex
        } else {
            guard let legacy = response.rateLimits,
                  legacy.limitId == nil || legacy.limitId == "codex" else {
                throw UsageError.noWeeklyLimit
            }
            bucket = legacy
        }
        guard let weekly = [bucket.primary, bucket.secondary].compactMap({ $0 })
            .first(where: { $0.windowDurationMins == 10_080 }) else {
            throw UsageError.noWeeklyLimit
        }
        let remaining = min(100, max(0, 100 - weekly.usedPercent))
        return UsageSnapshot(remainingPercent: Int(remaining.rounded(.down)))
    }
}

struct DisplayState {
    private(set) var remainingPercent: Int?
    private(set) var failed = false

    var title: String {
        "Codex \(remainingPercent.map(String.init) ?? "--")%" + (failed ? " !" : "")
    }

    mutating func succeed(_ snapshot: UsageSnapshot) {
        remainingPercent = snapshot.remainingPercent
        failed = false
    }

    mutating func fail() { failed = true }
}

struct CodexUsageReader {
    var executable: URL? = nil
    var timeout: TimeInterval = 15

    static func findExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = [
            home.appendingPathComponent(".local/bin/codex").path,
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            home.appendingPathComponent("Applications/Codex.app/Contents/Resources/codex").path
        ]
        paths += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { String($0) + "/codex" }
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map { URL(fileURLWithPath: $0) }
    }

    func fetch() throws -> UsageSnapshot {
        guard let binary = executable ?? Self.findExecutable() else { throw UsageError.cliMissing }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = binary
        process.arguments = ["app-server", "--stdio"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = binary.deletingLastPathComponent().path
            + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = environment
        do { try process.run() } catch { throw UsageError.connection }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            let stopAt = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning && ProcessInfo.processInfo.systemUptime < stopAt {
                Thread.sleep(forTimeInterval: 0.01)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var pending = Data()

        func send(_ object: [String: Any]) throws {
            var bytes = try JSONSerialization.data(withJSONObject: object)
            bytes.append(0x0a)
            do { try input.fileHandleForWriting.write(contentsOf: bytes) }
            catch { throw UsageError.connection }
        }

        func receive(id: Int) throws -> Data {
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let newline = pending.firstIndex(of: 0x0a) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any]
                    else { throw UsageError.invalidResponse }
                    guard let responseID = object["id"] as? Int, responseID == id else { continue }
                    if object["error"] != nil { throw UsageError.connection }
                    guard let result = object["result"] else { throw UsageError.invalidResponse }
                    return try JSONSerialization.data(withJSONObject: result)
                }
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor,
                                        events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Int32(max(1, remaining * 1000)))
                if ready == 0 { throw UsageError.timeout }
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw UsageError.connection
                }
                var bytes = [UInt8](repeating: 0, count: 8192)
                let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                guard count > 0 else { throw UsageError.connection }
                pending.append(contentsOf: bytes.prefix(count))
                guard pending.count <= 2_000_000 else { throw UsageError.invalidResponse }
            }
            throw UsageError.timeout
        }

        try send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "codex_usage_menubar", "version": "1.0.0"]
        ]])
        _ = try receive(id: 1)
        try send(["method": "initialized"])
        try send(["id": 2, "method": "account/rateLimits/read"])
        return try UsageSnapshot.parse(receive(id: 2))
    }
}
