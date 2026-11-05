import Foundation

/// Read-only local diagnostics. Commands run off the UI thread with bounded waits.
enum DiagnosticReport {
    static func collect(snapshot: String) -> String {
        var sections = [snapshot, "说明：仅采集本地状态，不访问外网，不更改网络配置。辅助程序状态为 App 最近一次检查结果。"]
        let commands: [(String, String, [String])] = [
            ("网络服务顺序", "/usr/sbin/networksetup", ["-listnetworkserviceorder"]),
            ("网络接口状态", "/sbin/ifconfig", ["-a"]),
            ("系统网络状态", "/usr/sbin/scutil", ["--nwi"]),
            ("DNS 配置", "/usr/sbin/scutil", ["--dns"]),
            ("系统代理配置", "/usr/sbin/scutil", ["--proxy"]),
            ("IPv4 路由表", "/usr/sbin/netstat", ["-rn", "-f", "inet"]),
            ("IPv6 路由表", "/usr/sbin/netstat", ["-rn", "-f", "inet6"]),
            ("辅助服务注册状态", "/bin/launchctl", ["print", "system/com.cooper.WorkRouteMenu.helper"])
        ]
        for (title, executable, arguments) in commands {
            sections.append("===== \(title) =====\n\(run(executable, arguments))")
        }
        let log = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/RouteDuo/service-order.log")
        sections.append("===== 服务顺序操作日志（最多末尾 256 KB） =====\n\(tail(log))")
        return sections.joined(separator: "\n\n") + "\n"
    }

    private static func tail(_ url: URL) -> String {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: size > 262144 ? size - 262144 : 0)
            return String(decoding: try handle.read(upToCount: 262144) ?? Data(), as: UTF8.self)
        } catch { return "无法读取：\(error.localizedDescription)" }
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String {
        // A file avoids pipe backpressure when routing/DNS output is large.
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard FileManager.default.createFile(atPath: output.path, contents: nil) else { return "无法创建采集文件" }
        defer { try? FileManager.default.removeItem(at: output) }
        do {
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = handle
            process.standardError = handle
            let ended = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in ended.signal() }
            try process.run()
            if ended.wait(timeout: .now() + 3) == .timedOut {
                process.terminate()
                if ended.wait(timeout: .now() + 0.5) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = ended.wait(timeout: .now() + 0.5)
                }
                return "采集超时（3 秒），已跳过。\n" + tail(output)
            }
            return "退出码：\(process.terminationStatus)\n" + tail(output)
        } catch { return "采集失败：\(error.localizedDescription)" }
    }
}
