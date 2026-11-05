import Foundation
import SystemConfiguration
import Security
import Darwin


@objc protocol RouteHelperProtocol {
    func healthCheck(withReply reply: @escaping (Bool, String) -> Void)
    func addRoutes(_ routes: [String], withReply reply: @escaping (Bool, String) -> Void)
    func deleteRoutes(_ routes: [String], withReply reply: @escaping (Bool, String) -> Void)
    func replaceRoutes(_ routesToDelete: [String], with routesToAdd: [String], withReply reply: @escaping (Bool, String) -> Void)
    func reorderNetworkServices(_ services: [String], withReply reply: @escaping (Bool, String) -> Void)
    func setNetworkServiceOrder(_ serviceIDs: [String], withReply reply: @escaping (Bool, String) -> Void)
}

// All route mutations and disconnect cleanup share one queue, so a late request
// cannot install routes after its owning connection has been invalidated.
private let routeQueue = DispatchQueue(label: "RouteDuo.helper.routes")
private struct OwnedRoute: Codable, Equatable {
    let ip: String
    let gateway: String
    let owner: UUID
}
enum RouteLookup {
    static func hasExactHostRoute(_ output: String, destination: String) -> Bool {
        let fields = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return fields.contains("destination: \(destination)") && fields.contains { field in
            guard field.hasPrefix("flags:"), let start = field.firstIndex(of: "<"),
                  let end = field.firstIndex(of: ">"), start < end else { return false }
            let flags = Set(field[field.index(after: start)..<end].split(separator: ","))
            return flags.contains("HOST") && !flags.contains("WASCLONED")
        }
    }
}

private final class RouteStore {
    static let shared = RouteStore()
    private let directory = URL(fileURLWithPath: "/Library/Application Support/RouteDuo", isDirectory: true)
    private var journal: URL { directory.appendingPathComponent("owned-routes.json") }
    var routes: [OwnedRoute] = []
    init() {
        if let data = try? Data(contentsOf: journal), let saved = try? JSONDecoder().decode([OwnedRoute].self, from: data) { routes = saved }
    }
    func save() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(routes).write(to: journal, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journal.path)
    }
    func run(_ args: [String]) -> (Bool, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/route")
        process.arguments = args
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return (false, error.localizedDescription) }
        if done.wait(timeout: .now() + 2) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return (false, "路由命令执行超时")
        }
        return (process.terminationStatus == 0, String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
    }
    // Only remove a host route that still has the gateway recorded by this helper.
    // Never flush the routing table or delete the system's default/network routes.
    func cleanup(owner: UUID? = nil) -> (Bool, String) {
        let targets = routes.filter { owner == nil || $0.owner == owner }
        var errors: [String] = []
        for route in targets {
            let result = run(["-n", "get", route.ip])
            guard result.0 else { errors.append("无法核对残留路由：\(route.ip)"); continue }
            let fields = result.1.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            let owned = fields.contains("destination: \(route.ip)") && fields.contains("gateway: \(route.gateway)") && fields.contains { $0.hasPrefix("flags:") && $0.contains("HOST") }
            if owned {
                let deleted = run(["-n", "delete", "-host", route.ip, route.gateway])
                if !deleted.0 { errors.append("\(route.ip)：\(deleted.1)"); continue }
            }
            routes.removeAll { $0 == route }
            do { try save() } catch { errors.append(error.localizedDescription) }
        }
        return (errors.isEmpty, errors.joined(separator: "\n"))
    }
}

final class RouteHelper: NSObject, RouteHelperProtocol {
    let owner = UUID()
    private var disconnected = false
    func disconnect() {
        routeQueue.async {
            self.disconnected = true
            let result = RouteStore.shared.cleanup(owner: self.owner)
            if !result.0 { NSLog("RouteDuo disconnect cleanup failed: %@", result.1) }
        }
    }
    private func perform(_ reply: @escaping (Bool, String) -> Void, _ action: @escaping () -> (Bool, String)) {
        routeQueue.async {
            guard !self.disconnected else { reply(false, "App 连接已断开，操作已取消"); return }
            let result = action(); reply(result.0, result.1)
        }
    }
    func healthCheck(withReply reply: @escaping (Bool, String) -> Void) {
        perform(reply) {
            // Retry journal entries left by a previous helper/App crash, excluding
            // routes owned by any still-live client session.
            let failed = RouteStore.shared.routes.filter { !Delegate.liveOwners.contains($0.owner) }
            for owner in Set(failed.map(\.owner)) {
                let result = RouteStore.shared.cleanup(owner: owner)
                if !result.0 { return result }
            }
            return (true, "RouteDuoHelper/3")
        }
    }
    private func parse(_ command: String, action: String) -> (String, String?)? {
        let parts = command.split(separator: " ").map(String.init)
        guard parts.count == (action == "add" ? 6 : 5), parts[0] == "route", parts[1] == "-n", parts[2] == action, parts[3] == "-host" else { return nil }
        var address = in_addr()
        guard inet_pton(AF_INET, parts[4], &address) == 1 else { return nil }
        if action == "add" {
            guard inet_pton(AF_INET, parts[5], &address) == 1 else { return nil }
            return (parts[4], parts[5])
        }
        return (parts[4], nil)
    }
    private func install(_ commands: [String]) -> (Bool, String) {
        let store = RouteStore.shared
        var committed = false
        defer { if !committed { _ = store.cleanup(owner: owner) } }
        let deadline = Date().addingTimeInterval(12)
        for command in commands {
            guard Date() < deadline else { _ = store.cleanup(owner: owner); return (false, "添加路由超时，已执行回滚") }
            guard let (ip, gatewayValue) = parse(command, action: "add"), let gateway = gatewayValue else { return (false, "无效的路由请求") }
            let route = OwnedRoute(ip: ip, gateway: gateway, owner: owner)
            if store.routes.contains(route) { continue }
            // Preserve any host route that RouteDuo did not create.
            let existing = store.run(["-n", "get", ip])
            // `route get` can return a HOST-marked lookup derived from a
            // broader route. Only an exact destination is a conflicting host route.
            if existing.0 && RouteLookup.hasExactHostRoute(existing.1, destination: ip) {
                _ = store.cleanup(owner: owner)
                return (false, "\(ip) 已有其他主机路由，未覆盖；请先检查已有路由")
            }
            store.routes.append(route)
            do { try store.save() } catch { store.routes.removeAll { $0 == route }; return (false, "无法记录路由恢复信息：\(error.localizedDescription)") }
            let result = store.run(["-n", "add", "-host", ip, gateway])
            if !result.0 { _ = store.cleanup(owner: owner); return result }
        }
        committed = true
        return (true, "")
    }
    func addRoutes(_ routes: [String], withReply reply: @escaping (Bool, String) -> Void) {
        perform(reply) { self.install(routes) }
    }
    func deleteRoutes(_ routes: [String], withReply reply: @escaping (Bool, String) -> Void) {
        // A disable always clears this session's complete applied set, independent
        // of the editable address list or a stale App-side cache.
        perform(reply) { RouteStore.shared.cleanup(owner: self.owner) }
    }
    func replaceRoutes(_ routesToDelete: [String], with routesToAdd: [String], withReply reply: @escaping (Bool, String) -> Void) {
        perform(reply) {
            let result = RouteStore.shared.cleanup(owner: self.owner)
            guard result.0 else { return result }
            return self.install(routesToAdd)
        }
    }
    func setNetworkServiceOrder(_ serviceIDs: [String], withReply reply: @escaping (Bool, String) -> Void) {
        routeQueue.async {
            guard !self.disconnected else { reply(false, "App 连接已断开"); return }
            self.applyNetworkServiceOrder(serviceIDs, withReply: reply)
        }
    }
    private func applyNetworkServiceOrder(_ serviceIDs: [String], withReply reply: @escaping (Bool, String) -> Void) {
        guard let prefs = SCPreferencesCreate(nil, "RouteDuo.PrivilegedOrder" as CFString, nil) else {
            reply(false, "无法创建系统配置会话"); return
        }
        guard SCPreferencesLock(prefs, false) else {
            reply(false, "无法锁定系统网络配置：\(String(cString: SCErrorString(SCError())))"); return
        }
        defer { SCPreferencesUnlock(prefs) }
        SCPreferencesSynchronize(prefs)
        guard let set = SCNetworkSetCopyCurrent(prefs),
              let current = SCNetworkSetGetServiceOrder(set) as? [String],
              current.count == serviceIDs.count, Set(current) == Set(serviceIDs),
              Set(serviceIDs).count == serviceIDs.count else {
            reply(false, "系统网络服务列表已变化，请重新打开后再应用"); return
        }
        let saved = SCNetworkSetSetServiceOrder(set, serviceIDs as CFArray)
        let committed = saved && SCPreferencesCommitChanges(prefs)
        let applied = committed && SCPreferencesApplyChanges(prefs)
        guard saved, committed, applied else {
            reply(false, "无法保存系统网络服务顺序：\(String(cString: SCErrorString(SCError())))")
            return
        }
        // 使用新的 preferences 会话回读，避免读到旧缓存。
        let verifyPrefs = SCPreferencesCreate(nil, "RouteDuo.VerifyOrder" as CFString, nil)
        let verify = verifyPrefs.flatMap { SCNetworkSetCopyCurrent($0) }.flatMap { SCNetworkSetGetServiceOrder($0) as? [String] }
        reply(verify == serviceIDs, verify == serviceIDs ? "" : "系统未确认新的服务顺序，请检查系统网络设置")
    }
    func reorderNetworkServices(_ services: [String], withReply reply: @escaping (Bool, String) -> Void) {
        reply(false, "旧接口不再受支持，请更新 App")
    }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    // Access only on routeQueue.
    static var liveOwners: Set<UUID> = []
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // The privileged route service accepts only our signed App from this team.
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        let rule = "anchor apple generic and identifier \"com.cooper.WorkRouteMenu\" and certificate leaf[subject.OU] = \"959Y964X4N\""
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess,
              let requirement, SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { return false }
        let session = RouteHelper()
        routeQueue.sync { _ = Self.liveOwners.insert(session.owner) }
        connection.exportedInterface = NSXPCInterface(with: RouteHelperProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = {
            session.disconnect()
            routeQueue.async { Self.liveOwners.remove(session.owner) }
        }
        connection.interruptionHandler = { connection.invalidate() }
        connection.resume()
        return true
    }
}

// Recover the durable journal before accepting any new routing operations.
routeQueue.sync {
    let result = RouteStore.shared.cleanup()
    if !result.0 { NSLog("RouteDuo startup cleanup failed: %@", result.1) }
}
let delegate = Delegate()
let listener = NSXPCListener(machServiceName: "com.cooper.WorkRouteMenu.helper")
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
