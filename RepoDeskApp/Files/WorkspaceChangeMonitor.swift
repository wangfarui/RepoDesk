import CoreServices
import Foundation

struct WorkspaceChangeBatch: Equatable, Sendable {
    var changedURLs: Set<URL>
    var requiresFullRescan: Bool
    var monitoringError: String?

    static func failure(_ message: String) -> WorkspaceChangeBatch {
        WorkspaceChangeBatch(
            changedURLs: [],
            requiresFullRescan: false,
            monitoringError: message
        )
    }
}

struct WorkspaceChangeScope: Sendable {
    let changedPaths: [String]
    let requiresFullRescan: Bool
    let hasMonitoringError: Bool

    init(_ batch: WorkspaceChangeBatch) {
        changedPaths = batch.changedURLs.map { $0.standardizedFileURL.path }
        requiresFullRescan = batch.requiresFullRescan
        hasMonitoringError = batch.monitoringError != nil
    }

    func affectsRepository(at repositoryURL: URL) -> Bool {
        guard !hasMonitoringError else { return false }
        if requiresFullRescan { return true }
        let repositoryPath = repositoryURL.standardizedFileURL.path
        let prefix = repositoryPath.hasSuffix("/") ? repositoryPath : repositoryPath + "/"
        return changedPaths.contains {
            $0 == repositoryPath || $0.hasPrefix(prefix)
        }
    }
}

protocol WorkspaceChangeMonitoring: Sendable {
    func events(in workspaceURL: URL) -> AsyncStream<WorkspaceChangeBatch>
}

struct SystemWorkspaceChangeMonitor: WorkspaceChangeMonitoring {
    let debounceInterval: TimeInterval

    init(debounceInterval: TimeInterval = 0.3) {
        self.debounceInterval = debounceInterval
    }

    func events(in workspaceURL: URL) -> AsyncStream<WorkspaceChangeBatch> {
        AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            let observer = WorkspaceFSEventObserver(
                workspaceURL: workspaceURL.standardizedFileURL,
                debounceInterval: debounceInterval,
                continuation: continuation
            )
            continuation.onTermination = { @Sendable _ in
                observer.stop()
            }
            observer.start()
        }
    }
}

enum WorkspaceTreeRefreshPlanner {
    static func directoriesToRefresh(
        for batch: WorkspaceChangeBatch,
        workspaceURL: URL,
        loadedDirectoryURLs: Set<URL>
    ) -> [URL] {
        let workspaceURL = workspaceURL.standardizedFileURL
        let loadedDirectoryURLs = Set(loadedDirectoryURLs.map(\.standardizedFileURL))
            .union([workspaceURL])

        if batch.requiresFullRescan {
            return sortedByDepth(loadedDirectoryURLs)
        }

        var affectedDirectories: Set<URL> = []
        let changedURLs = Set(batch.changedURLs.map(\.standardizedFileURL))
        for changedURL in changedURLs {
            let parentURL = changedURL.deletingLastPathComponent().standardizedFileURL
            if loadedDirectoryURLs.contains(changedURL) {
                affectedDirectories.insert(changedURL)
            }
            if loadedDirectoryURLs.contains(parentURL) {
                affectedDirectories.insert(parentURL)
            }
        }

        let changedPaths = Set(changedURLs.map(\.path))
        for loadedDirectoryURL in loadedDirectoryURLs {
            var candidateURL = loadedDirectoryURL
            while isSameOrDescendant(candidateURL, of: workspaceURL) {
                if changedPaths.contains(candidateURL.path) {
                    affectedDirectories.insert(loadedDirectoryURL)
                    break
                }
                guard candidateURL != workspaceURL else { break }
                let parentURL = candidateURL.deletingLastPathComponent().standardizedFileURL
                guard parentURL != candidateURL else { break }
                candidateURL = parentURL
            }
        }
        return sortedByDepth(affectedDirectories)
    }

    static func batch(_ batch: WorkspaceChangeBatch, affects directoryURL: URL) -> Bool {
        self.batch(batch, affectsRepositoryAt: directoryURL)
    }

    static func batch(
        _ batch: WorkspaceChangeBatch,
        affectsRepositoryAt repositoryURL: URL
    ) -> Bool {
        WorkspaceChangeScope(batch).affectsRepository(at: repositoryURL)
    }

    static func isSameOrDescendant(_ candidateURL: URL, of ancestorURL: URL) -> Bool {
        let candidatePath = candidateURL.standardizedFileURL.path
        let ancestorPath = ancestorURL.standardizedFileURL.path
        guard candidatePath != ancestorPath else { return true }
        let prefix = ancestorPath.hasSuffix("/") ? ancestorPath : ancestorPath + "/"
        return candidatePath.hasPrefix(prefix)
    }

    private static func sortedByDepth(_ urls: Set<URL>) -> [URL] {
        urls.sorted {
            let leftDepth = $0.pathComponents.count
            let rightDepth = $1.pathComponents.count
            if leftDepth != rightDepth { return leftDepth < rightDepth }
            return $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }
}

private final class WorkspaceFSEventObserver: @unchecked Sendable {
    private struct PollingFingerprint: Equatable {
        let modificationDate: Date?
        let fileSize: Int?
        let isDirectory: Bool
    }

    private let workspaceURL: URL
    private let debounceInterval: TimeInterval
    private let queue = DispatchQueue(label: "com.wangfarui.RepoDesk.workspace-events")
    private var continuation: AsyncStream<WorkspaceChangeBatch>.Continuation?
    private var stream: FSEventStreamRef?
    private var pendingURLs: Set<URL> = []
    private var pendingFullRescan = false
    private var flushWorkItem: DispatchWorkItem?
    private var usesDirectoryEventFallback = false
    private var pollingWorkItem: DispatchWorkItem?
    private var pollingSnapshot: [String: PollingFingerprint] = [:]

    init(
        workspaceURL: URL,
        debounceInterval: TimeInterval,
        continuation: AsyncStream<WorkspaceChangeBatch>.Continuation
    ) {
        self.workspaceURL = workspaceURL
        self.debounceInterval = debounceInterval
        self.continuation = continuation
    }

    func start() {
        queue.async { [self] in
            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )
            let flags = FSEventStreamCreateFlags(
                kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
            )
            if let stream = createAndStartStream(context: &context, flags: flags) {
                self.stream = stream
                return
            }
            usesDirectoryEventFallback = true
            if let stream = createAndStartStream(context: &context, flags: 0) {
                self.stream = stream
                return
            }
            startPollingFallback()
        }
    }

    private func createAndStartStream(
        context: inout FSEventStreamContext,
        flags: FSEventStreamCreateFlags
    ) -> FSEventStreamRef? {
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            workspaceEventCallback,
            &context,
            [workspaceURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounceInterval,
            flags
        ) else { return nil }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
        return stream
    }

    func stop() {
        queue.async { [self] in
            flushWorkItem?.cancel()
            flushWorkItem = nil
            pollingWorkItem?.cancel()
            pollingWorkItem = nil
            pollingSnapshot = [:]
            pendingURLs = []
            if let stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
            continuation = nil
        }
    }

    fileprivate func receive(
        paths: UnsafeMutableRawPointer,
        flags: UnsafePointer<FSEventStreamEventFlags>,
        count: Int
    ) {
        if usesDirectoryEventFallback {
            pendingFullRescan = true
        }
        let pathPointers = paths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
        for index in 0..<count {
            guard let pathPointer = pathPointers[index] else { continue }
            let path = String(cString: pathPointer)
            let eventFlags = flags[index]
            if eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
                || eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped) != 0
                || eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped) != 0
                || eventFlags & FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged) != 0 {
                pendingFullRescan = true
            }

            let url = URL(fileURLWithPath: path).standardizedFileURL
            if let repositoryURL = repositoryURLForRelevantGitMetadata(url) {
                pendingURLs.insert(repositoryURL)
                continue
            }
            if url.pathComponents.contains(".git") && !pendingFullRescan {
                continue
            }
            pendingURLs.insert(url)
        }
        scheduleFlush()
    }

    private func repositoryURLForRelevantGitMetadata(_ url: URL) -> URL? {
        let components = url.pathComponents
        guard let gitIndex = components.lastIndex(of: ".git") else { return nil }
        let metadataComponents = components.dropFirst(gitIndex + 1)
        let isRelevant: Bool
        if metadataComponents.isEmpty {
            isRelevant = true
        } else if let first = metadataComponents.first {
            isRelevant = first == "refs"
                || first == "logs"
                || [
                    "HEAD", "index", "packed-refs", "config", "MERGE_HEAD",
                    "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG"
                ].contains(first)
        } else {
            isRelevant = false
        }
        guard isRelevant else { return nil }
        let repositoryPath = NSString.path(withComponents: Array(components.prefix(gitIndex)))
        return URL(fileURLWithPath: repositoryPath, isDirectory: true).standardizedFileURL
    }

    private func scheduleFlush() {
        flushWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flush()
        }
        flushWorkItem = workItem
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    private func startPollingFallback() {
        pollingSnapshot = makePollingSnapshot()
        schedulePollingFallback()
    }

    private func schedulePollingFallback() {
        pollingWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.pollWorkspace()
        }
        pollingWorkItem = workItem
        queue.asyncAfter(
            deadline: .now() + max(1, debounceInterval),
            execute: workItem
        )
    }

    private func pollWorkspace() {
        guard continuation != nil else { return }
        let snapshot = makePollingSnapshot()
        if snapshot != pollingSnapshot {
            continuation?.yield(
                WorkspaceChangeBatch(
                    changedURLs: [workspaceURL],
                    requiresFullRescan: true,
                    monitoringError: nil
                )
            )
        }
        pollingSnapshot = snapshot
        schedulePollingFallback()
    }

    private func makePollingSnapshot() -> [String: PollingFingerprint] {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey, .fileSizeKey, .isDirectoryKey
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: workspaceURL,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else { return [:] }
        var snapshot: [String: PollingFingerprint] = [:]
        for case let itemURL as URL in enumerator {
            guard let values = try? itemURL.resourceValues(forKeys: keys) else { continue }
            snapshot[itemURL.standardizedFileURL.path] = PollingFingerprint(
                modificationDate: values.contentModificationDate,
                fileSize: values.fileSize,
                isDirectory: values.isDirectory == true
            )
        }
        return snapshot
    }

    private func flush() {
        guard !pendingURLs.isEmpty || pendingFullRescan else { return }
        continuation?.yield(
            WorkspaceChangeBatch(
                changedURLs: pendingURLs,
                requiresFullRescan: pendingFullRescan,
                monitoringError: nil
            )
        )
        pendingURLs = []
        pendingFullRescan = false
        flushWorkItem = nil
    }
}

private let workspaceEventCallback: FSEventStreamCallback = {
    _, context, eventCount, eventPaths, eventFlags, _ in
    guard let context else { return }
    let observer = Unmanaged<WorkspaceFSEventObserver>.fromOpaque(context).takeUnretainedValue()
    observer.receive(paths: eventPaths, flags: eventFlags, count: eventCount)
}
