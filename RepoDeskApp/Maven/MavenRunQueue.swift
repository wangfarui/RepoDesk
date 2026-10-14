import Foundation
import Observation

@Observable
@MainActor
final class MavenRunQueue {
    private(set) var activeRecords: [MavenRunRecord] = []
    private var presentations: [String: MavenExecutionPresentation] = [:]
    private var messages: [String: String] = [:]
    @ObservationIgnored private var lanes: [String: Lane] = [:]
    @ObservationIgnored private let runnerFactory: () -> any RepoTaskRunning
    @ObservationIgnored var onFinish: ((MavenRunRecord, URL) -> Void)?

    init(runnerFactory: @escaping () -> any RepoTaskRunning = { SystemRepoTaskRunner() }) {
        self.runnerFactory = runnerFactory
    }

    var hasRunningCommands: Bool {
        activeRecords.contains { $0.activity == .running }
    }

    func execution(for repositoryURL: URL?) -> MavenExecutionPresentation {
        guard let repositoryURL else { return .idle }
        return presentations[key(for: repositoryURL)] ?? .idle
    }

    func message(for repositoryURL: URL?) -> String? {
        guard let repositoryURL else { return nil }
        return messages[key(for: repositoryURL)]
    }

    func duplicateMessage(for request: MavenRunRequest, repositoryURL: URL) -> String? {
        guard let lane = lanes[key(for: repositoryURL)] else { return nil }
        if let current = lane.current, matches(current.request, request) {
            return "\(request.module.displayName) · \(request.goal.rawValue) 正在执行中。"
        }
        if let index = lane.waiting.firstIndex(where: { matches($0.request, request) }) {
            return "\(request.module.displayName) · \(request.goal.rawValue) 已在队列中，第 \(index + 1) 位。"
        }
        return nil
    }

    func submit(_ request: MavenRunRequest, repositoryURL: URL, workspaceURL: URL) {
        let repositoryURL = repositoryURL.standardizedFileURL.resolvingSymlinksInPath()
        let key = key(for: repositoryURL)
        let lane: Lane
        if let existing = lanes[key] {
            lane = existing
        } else {
            lane = Lane(repositoryURL: repositoryURL, runner: runnerFactory())
            lanes[key] = lane
        }
        guard !lane.stopping else {
            messages[key] = "正在停止当前命令，请等待停止完成后重试。"
            return
        }
        if let duplicate = duplicateMessage(for: request, repositoryURL: repositoryURL) {
            messages[key] = duplicate
            return
        }
        let entry = Entry(request: request, workspaceURL: workspaceURL)
        messages[key] = nil
        if lane.current == nil, lane.waiting.isEmpty {
            start(entry, lane: lane, key: key)
        } else {
            lane.waiting.append(entry)
            messages[key] = "已加入队列，第 \(lane.waiting.count) 位。"
            if lane.current == nil {
                start(lane.waiting.removeFirst(), lane: lane, key: key)
            } else {
                publishActiveRecords()
            }
        }
    }

    func remove(_ id: UUID) {
        for (key, lane) in lanes {
            guard let index = lane.waiting.firstIndex(where: { $0.id == id }) else { continue }
            lane.waiting.remove(at: index)
            messages[key] = "已移除等待中的命令。"
            publishActiveRecords()
            return
        }
    }

    func stop(repositoryURL: URL) {
        let key = key(for: repositoryURL)
        guard let lane = lanes[key], !lane.stopping else { return }
        let canceledCount = lane.waiting.count
        lane.waiting.removeAll()
        guard let current = lane.current else {
            publishActiveRecords()
            return
        }
        lane.stopping = true
        messages[key] = "正在停止当前命令，已取消 \(canceledCount) 条等待命令。"
        appendLog("\n用户停止执行，已取消 \(canceledCount) 条等待命令。\n", key: key)
        current.task?.cancel()
        let runner = lane.runner
        Task { [weak self] in
            await runner.stop()
            guard let self, self.lanes[key] === lane else { return }
            lane.stopFinished = true
            self.finishStoppingIfNeeded(lane, key: key)
        }
        publishActiveRecords()
    }

    func reset() {
        let previousLanes = Array(lanes.values)
        lanes.removeAll()
        presentations.removeAll()
        messages.removeAll()
        activeRecords.removeAll()
        for lane in previousLanes {
            lane.current?.task?.cancel()
            let runner = lane.runner
            Task { await runner.stop() }
        }
    }

    func clearLog(repositoryURL: URL) {
        let key = key(for: repositoryURL)
        presentations[key]?.log = ""
        publishActiveRecords()
    }

    private func start(_ entry: Entry, lane: Lane, key: String) {
        lane.current = entry
        entry.startedAt = .now
        presentations[key] = MavenExecutionPresentation(
            runningRequestID: entry.request.id,
            log: commandPreview(entry.request),
            terminationStatus: nil,
            duration: nil,
            finishedAt: nil,
            errorMessage: nil
        )
        publishActiveRecords()
        let request = entry.request
        let resolvedTask = ResolvedRepoTask(
            definitionID: request.id,
            name: "Maven \(request.goal.rawValue)",
            executableURL: request.command.executableURL,
            arguments: request.command.arguments,
            workingDirectoryURL: request.command.workingDirectoryURL,
            environment: request.command.environment,
            confirmation: request.requiresConfirmation ? .required : .none
        )
        let buffer = MavenQueueOutputBuffer()
        let runner = lane.runner
        entry.task = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await runner.run(resolvedTask) { [weak self] chunk in
                    guard buffer.append(chunk.text) else { return }
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(32))
                        guard let self, self.lanes[key] === lane, lane.current?.id == entry.id else {
                            _ = buffer.take()
                            return
                        }
                        self.appendLog(buffer.take(), key: key)
                    }
                }
                self?.finish(entry, lane: lane, key: key, result: result, error: nil, pending: buffer.take())
            } catch {
                self?.finish(entry, lane: lane, key: key, result: nil, error: error.localizedDescription, pending: buffer.take())
            }
        }
    }

    private func finish(
        _ entry: Entry,
        lane: Lane,
        key: String,
        result: TaskRunResult?,
        error: String?,
        pending: String
    ) {
        guard lanes[key] === lane, lane.current?.id == entry.id else { return }
        appendLog(pending, key: key)
        let startedAt = result?.startedAt ?? entry.startedAt
        let finishedAt = result?.finishedAt ?? .now
        let status = lane.stopping && result?.terminationStatus == 0 ? Int32(130) : result?.terminationStatus
        let failed = error != nil || status != 0
        presentations[key]?.runningRequestID = nil
        presentations[key]?.terminationStatus = status
        presentations[key]?.duration = max(0, finishedAt.timeIntervalSince(startedAt))
        presentations[key]?.finishedAt = finishedAt
        presentations[key]?.errorMessage = error
        if let error {
            appendLog("\nMaven 执行失败：\(error)\n", key: key)
        }
        if failed && !lane.stopping {
            let canceledCount = lane.waiting.count
            lane.waiting.removeAll()
            let reason = error ?? "退出码 \(status.map(String.init) ?? "未知")"
            let message = "Maven 执行失败（\(reason)），已取消 \(canceledCount) 条等待命令。"
            messages[key] = message
            appendLog("\n\(message)\n", key: key)
        }
        let record = makeRecord(entry, lane: lane, activity: nil, position: nil,
                                terminationStatus: status, startedAt: startedAt, finishedAt: finishedAt,
                                log: presentations[key]?.log)
        lane.current = nil
        publishActiveRecords()
        onFinish?(record, entry.workspaceURL)
        // Callbacks may reset the workspace or submit another command.
        guard lanes[key] === lane else { return }
        if lane.stopping {
            finishStoppingIfNeeded(lane, key: key)
        } else if lane.current == nil, !lane.waiting.isEmpty {
            let next = lane.waiting.removeFirst()
            messages[key] = nil
            start(next, lane: lane, key: key)
        }
    }

    private func finishStoppingIfNeeded(_ lane: Lane, key: String) {
        guard lane.stopping, lane.stopFinished, lane.current == nil else { return }
        lane.stopping = false
        lane.stopFinished = false
        messages[key] = "已停止执行，等待队列已清空。"
    }

    private func appendLog(_ text: String, key: String) {
        guard !text.isEmpty else { return }
        presentations[key]?.log.append(text)
        publishActiveRecords()
    }

    private func publishActiveRecords() {
        var records: [MavenRunRecord] = []
        for key in lanes.keys.sorted() {
            guard let lane = lanes[key] else { continue }
            if let current = lane.current {
                records.append(makeRecord(current, lane: lane, activity: .running, position: nil,
                                          log: presentations[key]?.log))
            }
            for (index, entry) in lane.waiting.enumerated() {
                records.append(makeRecord(entry, lane: lane, activity: .queued, position: index + 1,
                                          log: commandPreview(entry.request)))
            }
        }
        activeRecords = records
    }

    private func makeRecord(
        _ entry: Entry,
        lane: Lane,
        activity: MavenRunActivity?,
        position: Int?,
        terminationStatus: Int32? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        log: String?
    ) -> MavenRunRecord {
        MavenRunRecord(
            id: entry.id,
            repositoryURL: lane.repositoryURL,
            module: entry.request.module,
            goal: entry.request.goal,
            command: entry.request.command,
            terminationStatus: terminationStatus,
            startedAt: startedAt ?? entry.startedAt,
            finishedAt: finishedAt ?? entry.startedAt,
            log: log,
            activity: activity,
            queuePosition: position
        )
    }

    private func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func matches(_ lhs: MavenRunRequest, _ rhs: MavenRunRequest) -> Bool {
        lhs.module.modulePath == rhs.module.modulePath && lhs.goal == rhs.goal && lhs.command == rhs.command
    }

    private func commandPreview(_ request: MavenRunRequest) -> String {
        "$ \(request.command.displayComponents.joined(separator: " "))\n\n"
    }

    @MainActor
    private final class Lane {
        let repositoryURL: URL
        let runner: any RepoTaskRunning
        var current: Entry?
        var waiting: [Entry] = []
        var stopping = false
        var stopFinished = false

        init(repositoryURL: URL, runner: any RepoTaskRunning) {
            self.repositoryURL = repositoryURL
            self.runner = runner
        }
    }

    @MainActor
    private final class Entry {
        let id = UUID()
        let request: MavenRunRequest
        let workspaceURL: URL
        var startedAt = Date()
        var task: Task<Void, Never>?

        init(request: MavenRunRequest, workspaceURL: URL) {
            self.request = request
            self.workspaceURL = workspaceURL
        }
    }
}

private final class MavenQueueOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var flushScheduled = false

    func append(_ text: String) -> Bool {
        lock.withLock {
            pending.append(text)
            guard !flushScheduled else { return false }
            flushScheduled = true
            return true
        }
    }

    func take() -> String {
        lock.withLock {
            let text = pending
            pending = ""
            flushScheduled = false
            return text
        }
    }
}
