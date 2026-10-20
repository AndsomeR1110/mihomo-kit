// MihomoBar.swift — mihomo 菜单栏管家（Windows 托盘管家 v3 的 macOS 版）
// 单文件 Swift + AppKit 菜单栏程序，由 Xcode 命令行工具自带的 swiftc 编译（Swift 5.5 语法，macOS 12+，无外部依赖）。
// 编译与部署见同目录 build.sh / README.md。
//
// 功能契约与 Windows 托盘一致：
//   · 状态行：圆点 + 运行状态 + 当前出口节点（从 external-controller API 读取，密钥取自 config.yaml）
//   · 启动 / 停止 / 重启代理：免密（build.sh 写入的 sudoers 白名单），未授权时退回系统密码框
//   · 打开面板（⌥ 点击图标直达）、详细状态报告（终端里跑 status.command）、退出（内核不受影响）
//   · 状态变化发系统通知；图标为模板图，自动适配深浅色菜单栏：运行中=完整图标，停止=淡色空环

import AppKit
import UserNotifications

// ═══════════════════════════ 配置 ═══════════════════════════
enum Config {
    static let label = "com.mihomo-kit.mihomo"
    static let daemonPlist = "/Library/LaunchDaemons/com.mihomo-kit.mihomo.plist"
    static let apiFallback = "127.0.0.1:9097"

    // 出口显示从哪个策略组开始解析；留空 = 自动（rule 模式取 MATCH 规则指向的组，global 模式取 GLOBAL）
    static let exitGroup = ""

    static let pollInterval: TimeInterval = 3        // 服务状态轮询间隔
    static let exitRefreshSec: TimeInterval = 15     // 出口节点刷新间隔
    static let serviceTimeoutSec: TimeInterval = 20  // 启停等待上限

    // 套件根目录：build.sh 写进 Info.plist 的 MihomoKitRoot；没有则按 <根>/macos/menubar/MihomoBar.app 推算
    static let kitRoot: String = {
        if let s = Bundle.main.object(forInfoDictionaryKey: "MihomoKitRoot") as? String, !s.isEmpty, !s.hasPrefix("__") {
            return s
        }
        return Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().path
    }()
    static var configFile: String { return kitRoot + "/config/config.yaml" }
    static var statusCommand: String { return kitRoot + "/macos/status.command" }
}

// 菜单尺寸（pt）：自定义状态行宽度决定菜单最小宽度；提示文字右对齐到这个制表位
enum Layout {
    static let menuWidth: CGFloat = 250
    static let hintTab: CGFloat = 205
    static let textInset: CGFloat = 21   // 与系统菜单项文字左缘对齐
}

// ═══════════════════════════ 日志 ═══════════════════════════
enum Log {
    static let path = NSHomeDirectory() + "/Library/Logs/mihomo-menubar.log"

    static func write(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile()
            h.write(data)
            h.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

// ═══════════════════════════ 外部命令 ═══════════════════════════
struct ProcResult {
    let status: Int32
    let out: String
    let err: String
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String]) -> ProcResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return ProcResult(status: -1, out: "", err: error.localizedDescription)
        }
        // stderr 另起线程读，避免某一路写满管道互相卡死
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = e.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = o.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        p.waitUntilExit()
        return ProcResult(status: p.terminationStatus,
                          out: String(decoding: outData, as: UTF8.self),
                          err: String(decoding: errData, as: UTF8.self))
    }
}

// ═══════════════════════════ 守护进程启停 ═══════════════════════════
enum ServiceState { case unknown, missing, stopped, starting, running, stopping }

enum ServiceOps {
    static let target = "system/" + Config.label

    enum Op { case enable, bootout, bootstrap }

    static func args(_ op: Op) -> [String] {
        switch op {
        case .enable: return ["enable", target]
        case .bootout: return ["bootout", target]
        case .bootstrap: return ["bootstrap", "system", Config.daemonPlist]
        }
    }

    static func query() -> ServiceState {
        if !FileManager.default.fileExists(atPath: Config.daemonPlist) { return .missing }
        let r = Shell.run("/bin/launchctl", ["print", target])
        if r.status != 0 {
            // 113 = 没加载（已停止）；其他错误（个别系统上普通用户读不到 system 域）再用 API 兜底
            if r.status == 113 || r.err.contains("Could not find service") { return .stopped }
            return MihomoApi.alive() ? .running : .unknown
        }
        switch jobState(r.out) {
        case "running": return .running
        case "spawn scheduled": return .starting
        default: return .stopped
        }
    }

    // launchctl print 第一层缩进（一个制表符）的 state = xxx
    static func jobState(_ text: String) -> String {
        let prefix = "\tstate = "
        for line in text.components(separatedBy: "\n") where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    static func isLoaded() -> Bool {
        return Shell.run("/bin/launchctl", ["print", target]).status == 0
    }

    // 返回 nil = 成功，否则为错误说明
    static func start() -> String? {
        if query() == .running { return nil }
        var ops: [Op] = [.enable]
        if isLoaded() { ops.append(.bootout) }   // 已加载但没在跑（崩溃退避中）：卸了重载
        ops.append(.bootstrap)
        if let err = perform(ops) { return "启动失败：" + err }
        return waitFor { query() == .running } ? nil : "等待服务启动超时，可查看「详细状态报告」。"
    }

    static func stop() -> String? {
        if !isLoaded() { return nil }
        if let err = perform([.bootout]) { return "停止失败：" + err }
        return waitFor { !isLoaded() } ? nil : "等待服务停止超时，可查看「详细状态报告」。"
    }

    static func restart() -> String? {
        var ops: [Op] = []
        if isLoaded() { ops.append(.bootout) }
        ops += [.enable, .bootstrap]
        if let err = perform(ops) { return "重启失败：" + err }
        return waitFor { query() == .running } ? nil : "等待服务重启超时，可查看「详细状态报告」。"
    }

    static func waitFor(_ cond: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(Config.serviceTimeoutSec)
        while Date() < deadline {
            if cond() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return cond()
    }

    // 先走 sudo -n（sudoers 白名单，免密）；没有授权时整批交给系统密码框，只问一次
    static func perform(_ ops: [Op]) -> String? {
        for (i, op) in ops.enumerated() {
            let r = Shell.run("/usr/bin/sudo", ["-n", "/bin/launchctl"] + args(op))
            if r.status != 0 && i == 0 && r.err.contains("password") {
                return performWithPrompt(ops)
            }
            switch op {
            case .bootout:
                // bootout 的返回码不可靠（有时报 5 但其实已卸载），以实际是否卸载为准
                if !waitFor({ !isLoaded() }) { return firstLine(r.err, "无法卸载守护进程") }
            case .bootstrap:
                if r.status != 0 && !isLoaded() { return firstLine(r.err, "无法加载守护进程") }
            case .enable:
                if r.status != 0 { return firstLine(r.err, "无法恢复开机自启") }
            }
        }
        return nil
    }

    static func performWithPrompt(_ ops: [Op]) -> String? {
        var parts: [String] = []
        for op in ops {
            let cmd = (["/bin/launchctl"] + args(op)).map { "'" + $0 + "'" }.joined(separator: " ")
            switch op {
            case .bootout:
                parts.append(cmd + " 2>/dev/null; i=0; while /bin/launchctl print '\(target)' >/dev/null 2>&1"
                             + " && [ $i -lt 40 ]; do sleep 0.5; i=$((i+1)); done")
            default:
                parts.append(cmd)
            }
        }
        let shell = parts.joined(separator: "; ")
        let script = "do shell script \"\(appleScriptEscape(shell))\" with administrator privileges"
            + " with prompt \"mihomo 菜单栏需要管理员权限来启停代理。\""
        let r = Shell.run("/usr/bin/osascript", ["-e", script])
        if r.status == 0 { return nil }
        if r.err.contains("-128") { return "已取消。" }
        return firstLine(r.err, "授权失败")
    }

    static func appleScriptEscape(_ s: String) -> String {
        return s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func firstLine(_ s: String, _ fallback: String) -> String {
        let line = s.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.isEmpty ? fallback : line
    }
}

// ═══════════════════════════ mihomo API ═══════════════════════════
struct ApiEndpoint {
    let base: String
    let port: String
    let secret: String
}

enum ApiError: Error { case bad }

enum MihomoApi {
    static var matchGroup: String?
    static var matchAt = Date.distantPast

    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.connectionProxyDictionary = [:]   // 本机 API 绝不走系统代理
        c.timeoutIntervalForRequest = 2.5
        c.timeoutIntervalForResource = 2.5
        return URLSession(configuration: c)
    }()

    static let pathAllowed = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func endpoint() -> ApiEndpoint {
        let text = (try? String(contentsOfFile: Config.configFile, encoding: .utf8)) ?? ""
        var hostPort = configValue(text, "external-controller") ?? Config.apiFallback
        if hostPort.hasPrefix(":") { hostPort = "127.0.0.1" + hostPort }
        hostPort = hostPort.replacingOccurrences(of: "0.0.0.0", with: "127.0.0.1")
        let port = hostPort.components(separatedBy: ":").last ?? "9097"
        return ApiEndpoint(base: "http://" + hostPort, port: port, secret: configValue(text, "secret") ?? "")
    }

    // 与 common.ps1 的 Get-ConfigValue 同一条规则：顶格 key: 值（可带引号和行尾注释）
    static func configValue(_ text: String, _ key: String) -> String? {
        let pattern = "(?m)^" + NSRegularExpression.escapedPattern(for: key)
            + ":[ \\t]*\"?([^\"\\r\\n#]+?)\"?[ \\t]*(#.*)?$"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let v = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    static func panelURL() -> URL? {
        let ep = endpoint()
        if ep.secret.isEmpty || ep.secret.hasPrefix("__") { return nil }
        var c = URLComponents(string: ep.base + "/ui/")
        c?.queryItems = [URLQueryItem(name: "hostname", value: "127.0.0.1"),
                         URLQueryItem(name: "port", value: ep.port),
                         URLQueryItem(name: "secret", value: ep.secret)]
        return c?.url
    }

    static func alive() -> Bool {
        return (try? get(endpoint(), "/version")) != nil
    }

    // 解析当前“默认出口”：MATCH 规则指向的组 → 沿 now 一路展开到具体节点
    static func resolveExit() throws -> String? {
        let ep = endpoint()
        let configs = try get(ep, "/configs")
        let mode = str(configs, "mode").lowercased()
        if mode == "direct" { return "DIRECT" }

        var start = Config.exitGroup
        if start.isEmpty {
            if mode == "global" { start = "GLOBAL" } else { start = try matchGroupName(ep) ?? "" }
        }
        if start.isEmpty { return nil }

        var name = start
        for _ in 0..<8 {
            let enc = name.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? name
            let group = try get(ep, "/proxies/" + enc)
            let now = str(group, "now")
            if now.isEmpty || now == name { break }
            name = now
        }
        return name
    }

    static func friendly(_ name: String?) -> String? {
        guard let n = name, !n.isEmpty else { return nil }
        if n == "DIRECT" { return "直连" }
        if n == "REJECT" { return "拒绝" }
        return n
    }

    static func matchGroupName(_ ep: ApiEndpoint) throws -> String? {
        if let g = matchGroup, Date().timeIntervalSince(matchAt) < 300 { return g }
        var found: String?
        let r = try get(ep, "/rules")
        if let rules = r["rules"] as? [[String: Any]] {
            for rule in rules where str(rule, "type").lowercased() == "match" {
                found = str(rule, "proxy")
            }
        }
        matchGroup = found
        matchAt = Date()
        return found
    }

    // 同步请求，只在后台线程调用
    static func get(_ ep: ApiEndpoint, _ path: String) throws -> [String: Any] {
        guard let url = URL(string: ep.base + path) else { throw ApiError.bad }
        var req = URLRequest(url: url)
        if !ep.secret.isEmpty { req.setValue("Bearer " + ep.secret, forHTTPHeaderField: "Authorization") }
        let sem = DispatchSemaphore(value: 0)
        var body: Data?
        var failure: Error?
        var code = 0
        session.dataTask(with: req) { d, r, e in
            body = d
            failure = e
            code = (r as? HTTPURLResponse)?.statusCode ?? 0
            sem.signal()
        }.resume()
        sem.wait()
        if let e = failure { throw e }
        guard code == 200, let d = body,
              let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any] else { throw ApiError.bad }
        return obj
    }

    static func str(_ d: [String: Any], _ key: String) -> String {
        if let v = d[key] { return "\(v)" }
        return ""
    }
}

// ═══════════════════════════ 通知 ═══════════════════════════
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()
    var authorized = false

    func setup() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert]) { granted, err in
            DispatchQueue.main.async { self.authorized = granted }
            if let e = err { Log.write("通知授权失败：\(e.localizedDescription)") }
        }
    }

    func post(_ title: String, _ body: String) {
        if authorized {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req) { err in
                if err != nil { self.fallback(title, body) }
            }
        } else {
            fallback(title, body)
        }
    }

    // 未授权通知时退回 AppleScript 通知（显示为“脚本编辑器”）
    func fallback(_ title: String, _ body: String) {
        let esc = ServiceOps.appleScriptEscape
        let script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
        DispatchQueue.global(qos: .utility).async { Shell.run("/usr/bin/osascript", ["-e", script]) }
    }

    // 菜单栏程序常处于“前台”，默认不弹横幅；这里要求照常显示
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
}

// ═══════════════════════════ 外观 ═══════════════════════════
enum Icons {
    // 按 panel-icon.svg（512 视口）缩放绘制的模板图：外环 + 中间的分流“Y”
    static func make(running: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let s = rect.width / 512.0
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { return NSPoint(x: x * s, y: y * s) }
            NSColor.black.withAlphaComponent(running ? 1 : 0.5).set()

            let ring = NSBezierPath(ovalIn: NSRect(x: 60 * s, y: 60 * s, width: 392 * s, height: 392 * s))
            ring.lineWidth = 60 * s
            ring.stroke()

            if running {
                let flow = NSBezierPath()
                flow.lineWidth = 44 * s
                flow.lineCapStyle = .round
                flow.lineJoinStyle = .round
                flow.move(to: p(256, 336)); flow.line(to: p(256, 268))
                flow.move(to: p(256, 268)); flow.line(to: p(174, 206))
                flow.move(to: p(256, 268)); flow.line(to: p(338, 206))
                flow.stroke()
                NSBezierPath(ovalIn: NSRect(x: 228 * s, y: 240 * s, width: 56 * s, height: 56 * s)).fill()
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

enum Dot { case accent, muted, pending }

// 菜单第一行：圆点 + 状态 + 右侧出口节点（自定义视图，不可点击、不高亮）
final class HeaderView: NSView {
    let dot = NSView()
    let title = NSTextField(labelWithString: "")
    let hint = NSTextField(labelWithString: "")

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: Layout.menuWidth, height: 26))
        autoresizingMask = [.width]

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        title.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingTail
        hint.font = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.alignment = .right
        hint.lineBreakMode = .byTruncatingTail
        hint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for v in [dot, title, hint] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.centerXAnchor.constraint(equalTo: leadingAnchor, constant: Layout.textInset / 2 + 1),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.textInset),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            hint.centerYAnchor.constraint(equalTo: centerYAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func set(_ text: String, hint h: String?, dot kind: Dot) {
        title.stringValue = text
        hint.stringValue = h ?? ""
        let color: NSColor
        switch kind {
        case .accent: color = .systemGreen
        case .pending: color = .systemOrange
        case .muted: color = .systemGray
        }
        dot.layer?.backgroundColor = color.cgColor
    }
}

// ═══════════════════════════ 主程序 ═══════════════════════════
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    let header = HeaderView()
    var startItem = NSMenuItem(), stopItem = NSMenuItem(), restartItem = NSMenuItem()
    var panelItem = NSMenuItem(), reportItem = NSMenuItem(), quitItem = NSMenuItem()
    let iconOn = Icons.make(running: true)
    let iconOff = Icons.make(running: false)

    var timer: Timer?
    var state = ServiceState.unknown
    var stable = ServiceState.unknown   // 最近一次稳定态（运行/停止），用于判断是否发通知
    var busy = false
    var busyText = ""
    var exitName: String?
    var exitAt = Date.distantPast
    var fetching = false
    var polling = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            NSApp.terminate(nil)   // 已经有一个在运行
            return
        }
        Notifier.shared.setup()
        buildMenu()
        if let b = statusItem.button {
            b.image = iconOff
            b.target = self
            b.action = #selector(onClick(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        timer = Timer.scheduledTimer(withTimeInterval: Config.pollInterval, repeats: true) { [weak self] _ in
            self?.poll()
        }
        apply(ServiceOps.query())
        updateUi()
    }

    func buildMenu() {
        let headerItem = NSMenuItem()
        headerItem.view = header
        startItem = item("启动代理", nil, #selector(doStart))
        stopItem = item("停止代理", "完全直连", #selector(doStop))
        restartItem = item("重启代理", nil, #selector(doRestart))
        panelItem = item("打开面板", "⌥ 点击图标", #selector(openPanel))
        reportItem = item("详细状态报告", nil, #selector(openReport))
        quitItem = item("退出菜单栏图标", "内核不受影响", #selector(quit))

        menu.autoenablesItems = false
        menu.delegate = self
        let items: [NSMenuItem] = [headerItem, NSMenuItem.separator(), startItem, stopItem, restartItem,
                                   NSMenuItem.separator(), panelItem, reportItem, NSMenuItem.separator(), quitItem]
        for it in items { menu.addItem(it) }
    }

    func item(_ title: String, _ hint: String?, _ action: Selector) -> NSMenuItem {
        let it = NSMenuItem(title: title, action: action, keyEquivalent: "")
        it.target = self
        if let h = hint {
            let p = NSMutableParagraphStyle()
            p.tabStops = [NSTextTab(textAlignment: .right, location: Layout.hintTab)]
            let s = NSMutableAttributedString(string: title, attributes: [
                .font: NSFont.menuFont(ofSize: 0), .paragraphStyle: p])
            s.append(NSAttributedString(string: "\t" + h, attributes: [
                .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: p]))
            it.attributedTitle = s
        }
        return it
    }

    // ── 状态 ──────────────────────────────────────────
    func poll() {
        if polling { return }
        polling = true
        DispatchQueue.global(qos: .utility).async {
            let s = ServiceOps.query()
            DispatchQueue.main.async {
                self.polling = false
                self.apply(s)
            }
        }
    }

    func apply(_ s: ServiceState) {
        if s != state {
            state = s
            onStateChanged()
        }
        if state == .running && Date().timeIntervalSince(exitAt) >= Config.exitRefreshSec { refreshExit() }
    }

    func onStateChanged() {
        if !busy && (state == .running || state == .stopped) {
            if stable != .unknown && stable != state { notifyStable(state) }
            stable = state
        }
        if state != .running { exitName = nil }
        exitAt = Date.distantPast   // 状态一变就尽快刷新出口
        updateUi()
    }

    func notifyStable(_ s: ServiceState) {
        if s == .running { Notifier.shared.post("mihomo 已启动", "代理内核运行中") }
        else { Notifier.shared.post("mihomo 已停止", "已切换为完全直连") }
    }

    func updateUi() {
        let running = state == .running
        let starting = state == .starting
        var title: String
        var dot = Dot.muted

        if busy {
            title = busyText
            dot = .pending
        } else {
            switch state {
            case .running: title = "运行中"; dot = .accent
            case .stopped: title = "已停止（直连）"
            case .starting: title = "启动中…"; dot = .pending
            case .stopping: title = "停止中…"; dot = .pending
            case .missing: title = "未安装（先运行 install.command）"; dot = .pending
            case .unknown: title = "状态未知"
            }
        }

        header.set(title, hint: running && !busy ? exitName : nil, dot: dot)
        let installed = state != .missing
        startItem.isEnabled = installed && !busy && !running && !starting
        stopItem.isEnabled = installed && !busy && (running || starting)
        restartItem.isEnabled = installed && !busy && running

        statusItem.button?.image = running ? iconOn : iconOff
        var tip = "mihomo · " + title
        if running && !busy, let e = exitName, !e.isEmpty { tip += " · " + e }
        statusItem.button?.toolTip = tip
    }

    // ── 出口节点 ──────────────────────────────────────────
    func refreshExit() {
        if fetching { return }
        fetching = true
        exitAt = Date()
        DispatchQueue.global(qos: .utility).async {
            var name: String?
            var ok = true
            do { name = try MihomoApi.resolveExit() } catch { ok = false }
            DispatchQueue.main.async {
                self.fetching = false
                if !ok {   // 3 秒后重试
                    self.exitAt = Date().addingTimeInterval(3 - Config.exitRefreshSec)
                    return
                }
                if self.state != .running { return }
                let display = MihomoApi.friendly(name)
                if display != self.exitName {
                    self.exitName = display
                    self.updateUi()
                }
            }
        }
    }

    // ── 菜单栏交互 ──────────────────────────────────────────
    @objc func onClick(_ sender: Any?) {
        if let ev = NSApp.currentEvent, ev.type == .leftMouseUp, ev.modifierFlags.contains(.option) {
            openPanel()
            return
        }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuWillOpen(_ m: NSMenu) {
        apply(ServiceOps.query())   // 打开前同步一次，所见即所得
        updateUi()
        if state == .running && Date().timeIntervalSince(exitAt) > 3 { refreshExit() }
    }

    func menuDidClose(_ m: NSMenu) {
        statusItem.menu = nil   // 不常驻，下次点击仍走 onClick（才能识别 ⌥）
    }

    // ── 菜单动作 ──────────────────────────────────────────
    @objc func doStart() { runService("启动中…", ServiceOps.start, isRestart: false) }
    @objc func doStop() { runService("停止中…", ServiceOps.stop, isRestart: false) }
    @objc func doRestart() { runService("重启中…", ServiceOps.restart, isRestart: true) }

    func runService(_ text: String, _ op: @escaping () -> String?, isRestart: Bool) {
        if busy { return }
        busy = true
        busyText = text
        updateUi()

        DispatchQueue.global(qos: .userInitiated).async {
            let err = op()
            let now = ServiceOps.query()
            DispatchQueue.main.async {
                self.busy = false
                self.busyText = ""
                let before = self.stable
                self.state = now
                if now == .running || now == .stopped {
                    if err == nil {
                        if isRestart && now == .running { Notifier.shared.post("mihomo 已重启", "代理内核运行中") }
                        else if now != before { self.notifyStable(now) }
                    }
                    self.stable = now
                }
                if let e = err {
                    Log.write(e)
                    Notifier.shared.post("操作未完成", e)
                }
                if now != .running { self.exitName = nil }
                self.exitAt = Date.distantPast
                self.updateUi()
                self.poll()
            }
        }
    }

    @objc func openPanel() {
        guard let url = MihomoApi.panelURL() else {
            Notifier.shared.post("找不到面板地址", "config.yaml 里没有 secret，请先运行 install.command")
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc func openReport() {
        let path = Config.statusCommand
        guard FileManager.default.fileExists(atPath: path) else {
            Notifier.shared.post("找不到状态脚本", path)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Shell.run("/usr/bin/open", ["-a", "Terminal", path])
            if r.status != 0 { Log.write("打开状态报告失败：" + r.err) }
        }
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
