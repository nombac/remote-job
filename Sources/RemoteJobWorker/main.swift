import Foundation
import Darwin

enum JobError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case let .message(s) = self { return s }; return "error" }
}

let fm = FileManager.default
let jstISO8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "Asia/Tokyo")!
    return formatter
}()
let heartbeatInterval: TimeInterval = 20
let queuedCancelInterval: TimeInterval = 1
let staleAfter: TimeInterval = 180
let validIDCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-")
let validTaskCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")

struct JobRequest {
    let project: String
    let task: String
}

func configValue(_ path: String) throws -> String {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("WORK_ROOT=") }) else {
        throw JobError.message("WORK_ROOT is missing in \(path)")
    }
    let value = String(line.dropFirst("WORK_ROOT=".count))
    guard !value.isEmpty else { throw JobError.message("WORK_ROOT is empty") }
    return value
}

func atomicWrite(_ text: String, to url: URL) throws {
    try text.data(using: .utf8)!.write(to: url, options: .atomic)
}

func safeTarget(root: URL, relative: String) throws -> URL {
    guard !relative.isEmpty, !NSString(string: relative).isAbsolutePath,
          !relative.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
        throw JobError.message("project path must be relative and contain no '..'")
    }
    let realRoot = root.resolvingSymlinksInPath().standardizedFileURL
    let target = realRoot.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
    let prefix = realRoot.path.hasSuffix("/") ? realRoot.path : realRoot.path + "/"
    guard target.path == realRoot.path || target.path.hasPrefix(prefix) else {
        throw JobError.message("project resolves outside WORK_ROOT")
    }
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: target.path, isDirectory: &isDir), isDir.boolValue else {
        throw JobError.message("project directory does not exist")
    }
    return target
}

func status(_ state: String, id: String, project: String, task: String,
            detail: String = "", heartbeat: Bool = false) -> String {
    var lines = ["state=\(state)", "id=\(id)", "project=\(project)", "task=\(task)",
                 "updated=\(jstISO8601.string(from: Date()))"]
    if heartbeat { lines.append("heartbeat_epoch=\(Int(Date().timeIntervalSince1970))") }
    if !detail.isEmpty { lines.append(detail.replacingOccurrences(of: "\n", with: " ")) }
    return lines.joined(separator: "\n") + "\n"
}

func validID(_ id: String) -> Bool {
    !id.isEmpty && id.unicodeScalars.allSatisfy(validIDCharacters.contains)
}

func validTask(_ task: String) -> Bool {
    guard let first = task.unicodeScalars.first,
          CharacterSet.alphanumerics.contains(first) else { return false }
    return task.unicodeScalars.allSatisfy(validTaskCharacters.contains)
}

func parseRequest(_ url: URL) throws -> JobRequest {
    let text = try String(contentsOf: url, encoding: .utf8)
    guard text.hasSuffix("\n"), !text.hasSuffix("\n\n") else {
        throw JobError.message("request must end with exactly one newline")
    }
    let lines = text.dropLast().split(separator: "\n", omittingEmptySubsequences: false)
    guard lines.count == 3, lines[0] == "schema_version=2",
          lines[1].hasPrefix("project="), lines[2].hasPrefix("task=") else {
        throw JobError.message("invalid request format")
    }
    let project = String(lines[1].dropFirst("project=".count))
    let task = String(lines[2].dropFirst("task=".count))
    guard !project.isEmpty else { throw JobError.message("request project is empty") }
    guard validTask(task) else { throw JobError.message("invalid task name") }
    return JobRequest(project: project, task: task)
}

func cancelRequested(id: String, cancelDir: URL) -> Bool {
    let url = cancelDir.appendingPathComponent(id + ".cancel")
    guard let value = try? String(contentsOf: url, encoding: .utf8) else { return false }
    return value.trimmingCharacters(in: .whitespacesAndNewlines) == id
}

func cancelQueuedRequests(requests: URL, cancelDir: URL, statuses: URL) throws {
    let names = try fm.contentsOfDirectory(atPath: requests.path).filter { $0.hasSuffix(".request") }.sorted()
    for name in names {
        let id = String(name.dropLast(".request".count))
        guard validID(id), cancelRequested(id: id, cancelDir: cancelDir) else { continue }
        let statusURL = statuses.appendingPathComponent(id + ".status")
        guard !fm.fileExists(atPath: statusURL.path) else { continue }
        let requestURL = requests.appendingPathComponent(name)
        let request = try parseRequest(requestURL)
        try atomicWrite(status("cancelled", id: id, project: request.project, task: request.task), to: statusURL)
        try fm.removeItem(at: requestURL)
        try fm.removeItem(at: cancelDir.appendingPathComponent(id + ".cancel"))
    }
}

func spawn(entry: URL, target: URL, task: String, log: FileHandle) throws -> pid_t {
    var actions: posix_spawn_file_actions_t? = nil
    var attributes: posix_spawnattr_t? = nil
    guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0 else {
        throw JobError.message("posix_spawn initialization failed")
    }
    defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
    let chdirResult: Int32
    if #available(macOS 26.0, *) {
        chdirResult = posix_spawn_file_actions_addchdir(&actions, target.path)
    } else {
        chdirResult = posix_spawn_file_actions_addchdir_np(&actions, target.path)
    }
    guard chdirResult == 0,
          posix_spawn_file_actions_adddup2(&actions, log.fileDescriptor, STDOUT_FILENO) == 0,
          posix_spawn_file_actions_adddup2(&actions, log.fileDescriptor, STDERR_FILENO) == 0,
          posix_spawn_file_actions_addclose(&actions, log.fileDescriptor) == 0 else {
        throw JobError.message("posix_spawn file actions failed")
    }
    let flags = Int16(POSIX_SPAWN_SETPGROUP)
    guard posix_spawnattr_setflags(&attributes, flags) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0 else {
        throw JobError.message("posix_spawn process group setup failed")
    }
    let path = strdup(entry.path)!
    defer { free(path) }
    let taskArgument = strdup(task)!
    defer { free(taskArgument) }
    var argv: [UnsafeMutablePointer<CChar>?] = [path, taskArgument, nil]
    var pid: pid_t = 0
    let result = argv.withUnsafeMutableBufferPointer {
        posix_spawn(&pid, path, &actions, &attributes, $0.baseAddress!, environ)
    }
    guard result == 0 else { throw JobError.message("cannot start ./run: \(String(cString: strerror(result)))") }
    return pid
}

func processGroupExists(_ pgid: pid_t) -> Bool {
    kill(-pgid, 0) == 0 || errno == EPERM
}

func statusValue(_ key: String, text: String) -> String? {
    let prefix = key + "="
    guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else { return nil }
    return String(line.dropFirst(prefix.count))
}

func resolveStaleCancels(cancelDir: URL, statuses: URL) throws {
    let names = try fm.contentsOfDirectory(atPath: cancelDir.path).filter { $0.hasSuffix(".cancel") }.sorted()
    for name in names {
        let id = String(name.dropLast(".cancel".count))
        guard validID(id), cancelRequested(id: id, cancelDir: cancelDir) else { continue }
        let statusURL = statuses.appendingPathComponent(id + ".status")
        guard fm.fileExists(atPath: statusURL.path) else { continue }
        let text = try String(contentsOf: statusURL, encoding: .utf8)
        guard let state = statusValue("state", text: text), ["running", "cancelling"].contains(state) else {
            continue
        }
        guard statusValue("id", text: text) == id,
              let heartbeatText = statusValue("heartbeat_epoch", text: text),
              let heartbeat = TimeInterval(heartbeatText),
              let pgidText = statusValue("pgid", text: text),
              let pgid = pid_t(pgidText), pgid > 0 else {
            throw JobError.message("invalid stale status for \(id)")
        }
        guard Date().timeIntervalSince1970 - heartbeat > staleAfter else { continue }
        guard !processGroupExists(pgid) else { continue }
        if let project = statusValue("project", text: text), !project.isEmpty,
           let task = statusValue("task", text: text), validTask(task) {
            try atomicWrite(status("cancelled", id: id, project: project, task: task), to: statusURL)
        } else {
            // タスク導入前の旧statusは、安全確認に必要なID・heartbeat・pgidを検証してから状態だけ更新する。
            var lines = text.split(separator: "\n").map(String.init)
            guard let stateIndex = lines.firstIndex(where: { $0.hasPrefix("state=") }) else {
                throw JobError.message("invalid stale status for \(id)")
            }
            lines[stateIndex] = "state=cancelled"
            if let updatedIndex = lines.firstIndex(where: { $0.hasPrefix("updated=") }) {
                lines[updatedIndex] = "updated=\(jstISO8601.string(from: Date()))"
            } else {
                lines.append("updated=\(jstISO8601.string(from: Date()))")
            }
            try atomicWrite(lines.joined(separator: "\n") + "\n", to: statusURL)
        }
        try fm.removeItem(at: cancelDir.appendingPathComponent(name))
    }
}

func processPendingCancels(requests: URL, cancelDir: URL, statuses: URL) throws {
    try cancelQueuedRequests(requests: requests, cancelDir: cancelDir, statuses: statuses)
    try resolveStaleCancels(cancelDir: cancelDir, statuses: statuses)
}

func stopGroup(_ pgid: pid_t, childStatus: inout Int32, reaped: inout Bool) {
    _ = kill(-pgid, SIGTERM)
    let deadline = Date().addingTimeInterval(5)
    while processGroupExists(pgid), Date() < deadline {
        if !reaped, waitpid(pgid, &childStatus, WNOHANG) == pgid { reaped = true }
        usleep(100_000)
    }
    if processGroupExists(pgid) { _ = kill(-pgid, SIGKILL) }
    if !reaped { while waitpid(pgid, &childStatus, 0) < 0 && errno == EINTR {}; reaped = true }
}

func execute(id: String, project: String, task: String, target: URL, entry: URL, statusURL: URL,
             requests: URL, cancelDir: URL, statuses: URL) throws {
    let logURL = statuses.appendingPathComponent(id + ".log")
    fm.createFile(atPath: logURL.path, contents: nil)
    let log = try FileHandle(forWritingTo: logURL)
    defer { try? log.close() }
    let pid = try spawn(entry: entry, target: target, task: task, log: log)
    var childStatus: Int32 = 0
    var reaped = false
    do {
        try atomicWrite(status("running", id: id, project: project, task: task, detail: "pgid=\(pid)", heartbeat: true), to: statusURL)
        var nextHeartbeat = Date().addingTimeInterval(heartbeatInterval)
        var nextQueuedCancel = Date()
        while true {
            let waited = waitpid(pid, &childStatus, WNOHANG)
            if waited == pid { reaped = true; break }
            if waited < 0 && errno != EINTR { throw JobError.message("waitpid failed") }
            if cancelRequested(id: id, cancelDir: cancelDir) {
                try atomicWrite(status("cancelling", id: id, project: project, task: task, detail: "pgid=\(pid)", heartbeat: true), to: statusURL)
                stopGroup(pid, childStatus: &childStatus, reaped: &reaped)
                try atomicWrite(status("cancelled", id: id, project: project, task: task), to: statusURL)
                try? fm.removeItem(at: cancelDir.appendingPathComponent(id + ".cancel"))
                return
            }
            if Date() >= nextQueuedCancel {
                try processPendingCancels(requests: requests, cancelDir: cancelDir, statuses: statuses)
                nextQueuedCancel = Date().addingTimeInterval(queuedCancelInterval)
            }
            if Date() >= nextHeartbeat {
                try atomicWrite(status("running", id: id, project: project, task: task, detail: "pgid=\(pid)", heartbeat: true), to: statusURL)
                nextHeartbeat = Date().addingTimeInterval(heartbeatInterval)
            }
            usleep(200_000)
        }
        let exited = (childStatus & 0x7f) == 0
        let code = (childStatus >> 8) & 0xff
        let ok = exited && code == 0
        let detail = exited ? "exit=\(code)" : "signal=\(childStatus & 0x7f)"
        try atomicWrite(status(ok ? "finished" : "error", id: id, project: project, task: task, detail: detail), to: statusURL)
    } catch {
        if !reaped { stopGroup(pid, childStatus: &childStatus, reaped: &reaped) }
        throw error
    }
}

func cleanTerminalCancels(cancelDir: URL, statuses: URL) throws {
    for name in try fm.contentsOfDirectory(atPath: cancelDir.path) where name.hasSuffix(".cancel") {
        let id = String(name.dropLast(".cancel".count))
        guard validID(id), cancelRequested(id: id, cancelDir: cancelDir),
              let text = try? String(contentsOf: statuses.appendingPathComponent(id + ".status"), encoding: .utf8),
              let state = text.split(separator: "\n").first(where: { $0.hasPrefix("state=") }) else { continue }
        if ["state=finished", "state=error", "state=cancelled"].contains(String(state)) {
            try? fm.removeItem(at: cancelDir.appendingPathComponent(name))
        }
    }
}

func runOne(configPath: String) throws {
    guard geteuid() != 0 else { throw JobError.message("refusing to run as root") }
    let root = URL(fileURLWithPath: try configValue(configPath), isDirectory: true)
    let lockURL = URL(fileURLWithPath: configPath).deletingLastPathComponent().appendingPathComponent("worker.lock")
    let lockFD = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard lockFD >= 0 else { throw JobError.message("cannot open worker lock") }
    if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
        let lockError = errno
        close(lockFD)
        if lockError == EWOULDBLOCK { return }
        throw JobError.message("cannot acquire worker lock")
    }
    _ = fcntl(lockFD, F_SETFD, FD_CLOEXEC)
    defer { flock(lockFD, LOCK_UN); close(lockFD) }

    let remote = root.appendingPathComponent(".remote", isDirectory: true)
    let requests = remote.appendingPathComponent("requests", isDirectory: true)
    let statuses = remote.appendingPathComponent("status", isDirectory: true)
    let cancelDir = remote.appendingPathComponent("cancel", isDirectory: true)
    for dir in [requests, statuses, cancelDir] { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }

    try cleanTerminalCancels(cancelDir: cancelDir, statuses: statuses)
    try processPendingCancels(requests: requests, cancelDir: cancelDir, statuses: statuses)

    let names = try fm.contentsOfDirectory(atPath: requests.path).filter { $0.hasSuffix(".request") }.sorted()
    for name in names {
        let id = String(name.dropLast(".request".count))
        guard validID(id) else { continue }
        let stateURL = statuses.appendingPathComponent(id + ".status")
        if fm.fileExists(atPath: stateURL.path) { continue }
        let requestURL = requests.appendingPathComponent(name)
        var request: JobRequest? = nil
        do {
            let parsedRequest = try parseRequest(requestURL)
            request = parsedRequest
            let target = try safeTarget(root: root, relative: parsedRequest.project)
            let entry = target.appendingPathComponent("run")
            guard fm.isExecutableFile(atPath: entry.path) else { throw JobError.message("./run is not executable") }
            try execute(id: id, project: parsedRequest.project, task: parsedRequest.task,
                        target: target, entry: entry,
                        statusURL: stateURL, requests: requests, cancelDir: cancelDir, statuses: statuses)
        } catch {
            try atomicWrite(status("error", id: id, project: request?.project ?? "invalid",
                                   task: request?.task ?? "invalid", detail: "error=\(error)"), to: stateURL)
        }
        return
    }
}

do {
    let configPath: String
    if CommandLine.arguments.count == 1 {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        configPath = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("config").path
    } else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--config" {
        configPath = CommandLine.arguments[2]
    } else {
        throw JobError.message("usage: job-worker [--config PATH]")
    }
    try runOne(configPath: configPath)
} catch {
    FileHandle.standardError.write("remote-job-worker: \(error)\n".data(using: .utf8)!)
    exit(1)
}
