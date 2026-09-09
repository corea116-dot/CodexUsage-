import Foundation
import Darwin

@main
enum UsageTests {
    static func main() throws {
        signal(SIGPIPE, SIG_IGN)
        var count = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fatalError("FAIL: \(name)") }
            count += 1
            print("PASS: \(name)")
        }
        func parse(_ json: String) throws -> UsageSnapshot {
            try UsageSnapshot.parse(Data(json.utf8))
        }
        let primary = #"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":11,"windowDurationMins":10080}}}"#
        check(try parse(primary).remainingPercent == 89, "weekly primary window")
        let secondary = #"{"rateLimits":{"primary":{"usedPercent":90,"windowDurationMins":300},"secondary":{"usedPercent":12,"windowDurationMins":10080}}}"#
        check(try parse(secondary).remainingPercent == 88, "weekly secondary, not five-hour window")
        let buckets = #"{"rateLimits":{"primary":{"usedPercent":90,"windowDurationMins":10080}},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":11,"windowDurationMins":10080}},"codex_bengalfox":{"secondary":{"usedPercent":0,"windowDurationMins":10080}}}}"#
        check(try parse(buckets).remainingPercent == 89, "Codex bucket preferred over legacy and Spark")
        let missing = #"{"rateLimits":{"primary":{"usedPercent":11,"windowDurationMins":300}}}"#
        do { _ = try parse(missing); fatalError("accepted missing weekly window") }
        catch { check(error is UsageError, "missing weekly limit rejected") }
        let onlySpark = #"{"rateLimitsByLimitId":{"codex_bengalfox":{"primary":{"usedPercent":11,"windowDurationMins":10080}}}}"#
        do { _ = try parse(onlySpark); fatalError("accepted Spark as Codex") }
        catch { check(error is UsageError, "Spark-only response rejected") }
        do { _ = try parse("null"); fatalError("accepted null") }
        catch { check(true, "malformed response rejected") }
        let fraction = primary.replacingOccurrences(of: "\"usedPercent\":11", with: "\"usedPercent\":11.4")
        check(try parse(fraction).remainingPercent == 88, "fraction does not overstate remaining")
        check(try parse(primary.replacingOccurrences(of: ":11,", with: ":120,")).remainingPercent == 0, "over-limit clamps to zero")
        check(try parse(primary.replacingOccurrences(of: ":11,", with: ":0,")).remainingPercent == 100, "unused limit displays 100 percent")
        var state = DisplayState()
        check(state.title == "Codex --%", "initial unknown state")
        state.fail()
        check(state.title == "Codex --% !", "first failure stays unknown")
        state.succeed(try parse(primary))
        check(state.title == "Codex 89%", "successful initial fetch clears failure")
        state.fail()
        check(state.title == "Codex 89% !", "failed refresh preserves last value")
        state.succeed(UsageSnapshot(remainingPercent: 88))
        check(state.title == "Codex 88%", "recovery changes value and removes exclamation")

        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        func helper(_ body: String, _ name: String) throws -> URL {
            let file = temporary.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            return file
        }
        let valid = try helper("""
        IFS= read -r line
        case "$line" in *initialize*) ;; *) exit 3;; esac
        printf '%s\\n' '{"id":1,"result":{}}'
        IFS= read -r line
        case "$line" in *initialized*) ;; *) exit 4;; esac
        IFS= read -r line
        case "$line" in *account*rateLimits*read*) ;; *) exit 5;; esac
        printf '%s\\n' '{"method":"notice"}' '{"id":999,"result":{}}'
        printf '%s' '{"id":2,"result":'
        printf '%s\\n' '\(primary)}'
        """, "valid-helper")
        let snapshot = try CodexUsageReader(executable: valid, timeout: 2).fetch()
        check(snapshot.remainingPercent == 89, "real stdio handshake, notifications and partial records")
        let silent = try helper("exec /bin/sleep 5\n", "silent-helper")
        let started = ProcessInfo.processInfo.systemUptime
        do {
            _ = try CodexUsageReader(executable: silent, timeout: 0.15).fetch()
            fatalError("silent helper accepted")
        } catch {
            check(ProcessInfo.processInfo.systemUptime - started < 2, "timeout stops helper promptly")
        }
        let dead = try helper("exit 0\n", "dead-helper")
        do { _ = try CodexUsageReader(executable: dead, timeout: 1).fetch(); fatalError("dead helper accepted") }
        catch { check(true, "early helper exit does not kill client") }
        print("\(count) checks passed")
    }
}
