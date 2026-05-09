import Foundation
import Darwin
import Dispatch

let usage = """
meian-watcher: macOS Light/Dark mode watcher for Neovim.

Usage:
  meian-watcher [--base-dir <dir>] [--idle-timeout <sec>]

Options:
  --base-dir <dir>      Base directory for the lock file and subscribers
                        (default: $XDG_RUNTIME_DIR/meian-mac-appearance, or
                         /tmp/meian-mac-appearance, or $MEIAN_BASE_DIR).
  --idle-timeout <sec>  Exit when no subscribers exist for this many seconds.
                        0 disables the timeout. (default: 60)
  -h, --help            Show this help message.
"""

struct Options {
    var baseDir: String = {
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_RUNTIME_DIR"], !xdg.isEmpty {
            return xdg + "/meian-mac-appearance"
        }
        return "/tmp/meian-mac-appearance"
    }()
    var idleTimeout: TimeInterval = 60
}

func parseArguments() -> Options {
    var opts = Options()
    if let env = ProcessInfo.processInfo.environment["MEIAN_BASE_DIR"], !env.isEmpty {
        opts.baseDir = env
    }
    let args = CommandLine.arguments
    var i = 1
    while i < args.count {
        let arg = args[i]
        switch arg {
        case "--base-dir":
            i += 1
            guard i < args.count else {
                FileHandle.standardError.write(Data("meian-watcher: --base-dir requires a value\n".utf8))
                exit(2)
            }
            opts.baseDir = args[i]
        case "--idle-timeout":
            i += 1
            guard i < args.count, let t = TimeInterval(args[i]) else {
                FileHandle.standardError.write(Data("meian-watcher: --idle-timeout requires a number\n".utf8))
                exit(2)
            }
            opts.idleTimeout = t
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            FileHandle.standardError.write(Data("meian-watcher: unknown argument: \(arg)\n".utf8))
            exit(2)
        }
        i += 1
    }
    return opts
}

let options = parseArguments()
let lockPath = "\(options.baseDir)/watch.lock"
let subscribersDir = "\(options.baseDir)/subscribers"
let globalPreferencesPath = "\(NSHomeDirectory())/Library/Preferences/.GlobalPreferences.plist"
let fm = FileManager.default

do {
    try fm.createDirectory(atPath: options.baseDir, withIntermediateDirectories: true)
    try fm.createDirectory(atPath: subscribersDir, withIntermediateDirectories: true)
} catch {
    FileHandle.standardError.write(Data("meian-watcher: failed to create base dir: \(error)\n".utf8))
    exit(1)
}

let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o644)
guard lockFD >= 0 else {
    FileHandle.standardError.write(Data("meian-watcher: failed to open lock: \(lockPath)\n".utf8))
    exit(1)
}

if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    // Another watcher is already running. Exit silently.
    exit(0)
}

ftruncate(lockFD, 0)
let pidLine = "\(getpid())\n"
_ = pidLine.withCString { ptr in write(lockFD, ptr, strlen(ptr)) }

let nullFD = open("/dev/null", O_RDWR)
if nullFD >= 0 {
    dup2(nullFD, 0)
    dup2(nullFD, 1)
    dup2(nullFD, 2)
    if nullFD > 2 { close(nullFD) }
}

@Sendable func currentAppearance() -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    task.arguments = ["read", "-g", "AppleInterfaceStyle"]
    let pipe = Pipe()
    task.standardOutput = pipe
    if let null = FileHandle(forWritingAtPath: "/dev/null") {
        task.standardError = null
    }
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let str = String(data: data, encoding: .utf8),
           str.lowercased().contains("dark") {
            return "dark"
        }
    } catch {}
    return "light"
}

struct Subscriber {
    let file: String
    let socket: String
    let nvim: String
}

@Sendable func loadSubscribers() -> [Subscriber] {
    guard let entries = try? fm.contentsOfDirectory(atPath: subscribersDir) else {
        return []
    }
    var results: [Subscriber] = []
    for entry in entries {
        guard entry.hasSuffix(".json") else { continue }
        let path = "\(subscribersDir)/\(entry)"
        guard let data = fm.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let socket = json["socket"] as? String, !socket.isEmpty
        else { continue }
        let nvim = (json["nvim"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "nvim"
        results.append(Subscriber(file: path, socket: socket, nvim: nvim))
    }
    return results
}

@discardableResult
@Sendable func sendToNvim(_ sub: Subscriber, appearance: String) -> Bool {
    let task = Process()
    let keys = "<Cmd>lua require('meian').apply('\(appearance)')<CR>"
    let nvimArgs = ["--server", sub.socket, "--remote-send", keys]

    if sub.nvim.hasPrefix("/") {
        task.executableURL = URL(fileURLWithPath: sub.nvim)
        task.arguments = nvimArgs
    } else {
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = [sub.nvim] + nvimArgs
    }
    if let null = FileHandle(forWritingAtPath: "/dev/null") {
        task.standardOutput = null
        task.standardError = null
    }
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus == 0
    } catch {
        return false
    }
}

@Sendable func notifyAll(appearance: String) {
    for sub in loadSubscribers() {
        if !sendToNvim(sub, appearance: appearance) {
            // Stale subscriber (process gone, socket dead) — clean up.
            try? fm.removeItem(atPath: sub.file)
        }
    }
}

var lastAppearance = currentAppearance()

@Sendable func notifyIfChanged() {
    let appearance = currentAppearance()
    if appearance == lastAppearance {
        return
    }
    lastAppearance = appearance
    notifyAll(appearance: appearance)
}

@Sendable func scheduleAppearanceCheck() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        notifyIfChanged()
    }
}

final class PreferenceFileWatcher {
    private let filePath: String
    private let onChange: () -> Void
    private var fileSource: DispatchSourceFileSystemObject?

    init(filePath: String, onChange: @escaping () -> Void) {
        self.filePath = filePath
        self.onChange = onChange
    }

    func start() {
        watchFile()
    }

    private func watchFile() {
        fileSource?.cancel()
        fileSource = nil

        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else {
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self = self else { return }
            let data = source?.data ?? []
            self.onChange()
            if data.contains(.delete) || data.contains(.rename) {
                self.watchFile()
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        fileSource = source
        source.resume()
    }
}

var lastSeenSubscriber = Date()

@Sendable func checkIdle() {
    if options.idleTimeout <= 0 { return }
    if loadSubscribers().isEmpty {
        if Date().timeIntervalSince(lastSeenSubscriber) >= options.idleTimeout {
            exit(0)
        }
    } else {
        lastSeenSubscriber = Date()
    }
}

let preferenceWatcher = PreferenceFileWatcher(filePath: globalPreferencesPath) {
    scheduleAppearanceCheck()
}
preferenceWatcher.start()

Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
    checkIdle()
}

RunLoop.main.run()
