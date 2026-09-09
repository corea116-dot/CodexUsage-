import AppKit
import Foundation
import ServiceManagement
import OSLog
import Darwin

private let appID = "local.codex.usage-menubar"
private let statusURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Codex Usage/status.json")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private var timer: Timer?
    private var state = DisplayState()
    private var refreshing = false
    private var refreshCount = 0
    private var lastSuccess: Date?
    private var lastError: String?
    private var trigger = "launch"
    private var loginStatus = "unknown"
    private var wakeObserver: NSObjectProtocol?
    private let queue = DispatchQueue(label: "local.codex.usage-reader", qos: .utility)

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSRunningApplication.runningApplications(withBundleIdentifier: appID)
            .contains(where: { $0.processIdentifier != getpid() }) {
            NSApp.terminate(nil)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp])
            button.setAccessibilityLabel("Codex 주간 남은 한도")
        }
        registerLogin()
        render()
        refresh(reason: "launch")
        let pollingTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh(reason: "timer")
        }
        pollingTimer.tolerance = 1
        RunLoop.main.add(pollingTimer, forMode: .common)
        timer = pollingTimer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh(reason: "wake") }
    }

    private func registerLogin() {
        do {
            if SMAppService.mainApp.status == .notRegistered || SMAppService.mainApp.status == .notFound {
                try SMAppService.mainApp.register()
            }
            loginStatus = Self.loginStatusName
        } catch {
            loginStatus = "registrationFailed:\((error as NSError).code)"
        }
    }

    static var loginStatusName: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "enabled"
        case .notRegistered: return "notRegistered"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    @objc private func clicked() { refresh(reason: "click") }

    private func refresh(reason: String) {
        guard !refreshing else { return }
        refreshing = true
        trigger = reason
        render()
        queue.async { [weak self] in
            let result = Result { try CodexUsageReader().fetch() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.refreshing = false
                self.refreshCount += 1
                switch result {
                case .success(let snapshot):
                    self.state.succeed(snapshot)
                    self.lastSuccess = Date()
                    self.lastError = nil
                case .failure(let error):
                    self.state.fail()
                    self.lastError = (error as? UsageError)?.errorDescription
                        ?? "사용량 응답을 읽을 수 없습니다."
                }
                self.render()
            }
        }
    }

    private func render() {
        item.button?.title = state.title
        item.button?.setAccessibilityValue(state.title)
        persistStatus()
    }

    private func persistStatus() {
        var status: [String: Any] = [
            "title": state.title,
            "failed": state.failed,
            "refreshing": refreshing,
            "completedRefreshes": refreshCount,
            "lastTrigger": trigger,
            "intervalSeconds": 60,
            "loginStatus": loginStatus,
            "pid": getpid()
        ]
        if let value = state.remainingPercent { status["remainingPercent"] = value }
        if let lastSuccess {
            status["lastSuccess"] = ISO8601DateFormatter().string(from: lastSuccess)
        }
        if let lastError { status["lastError"] = lastError }
        do {
            try FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: status, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: statusURL, options: .atomic)
        } catch {
            Logger(subsystem: appID, category: "status").error("Could not write display status.")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
    }
}

@main
enum CodexUsageApp {
    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if !arguments.isEmpty {
            switch arguments {
            case ["--help"], ["-h"]:
                print("""
                Codex Usage — 메뉴바에 Codex 주간 잔여량을 표시합니다.
                사용법: CodexUsage [--check | --status | --login-status | --help]
                  인수 없음       메뉴바 실행, 1분마다 및 클릭 시 새로고침
                  --check         현재 계정의 주간 잔여량을 한 번 조회
                  --status        실행 중인 앱이 마지막으로 기록한 상태 출력
                  --login-status  macOS 로그인 자동 실행 등록 상태 확인
                """)
            case ["--check"]:
                do {
                    let snapshot = try CodexUsageReader().fetch()
                    print("Codex \(snapshot.remainingPercent)%")
                } catch {
                    fputs("\((error as? UsageError)?.errorDescription ?? "사용량 조회 실패")\n", stderr)
                    exit(1)
                }
            case ["--status"]:
                guard let data = try? Data(contentsOf: statusURL),
                      let text = String(data: data, encoding: .utf8) else {
                    fputs("앱 상태 기록이 없습니다.\n", stderr)
                    exit(1)
                }
                print(text)
            case ["--login-status"]:
                print(AppDelegate.loginStatusName)
            default:
                fputs("지원하지 않는 인수입니다. --help를 확인해 주세요.\n", stderr)
                exit(2)
            }
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
