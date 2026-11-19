import Foundation

enum JavaLanguageProviderEvent: Equatable, Sendable {
    case snapshot(JavaIndexSnapshot)
}

protocol JavaLanguageProviding: Sendable {
    var events: AsyncStream<JavaLanguageProviderEvent> { get }

    func configure(_ settings: JavaIndexSettings) async
    func updateWorkspace(
        workspaceURL: URL?,
        repositories: [RegisteredRepository],
        projectJavaHome: String?,
        mavenUserSettingsFile: String?,
        mavenLocalRepositoryURL: URL?
    ) async
    func prioritize(repositoryID: RegisteredRepository.ID) async
    func navigationTargets(
        repositoryID: RegisteredRepository.ID,
        request: JavaNavigationRequest
    ) async -> [JavaNavigationTarget]
    func searchSymbols(_ request: JavaSymbolSearchRequest) async -> [JavaNavigationTarget]
    func semanticTokens(
        repositoryID: RegisteredRepository.ID,
        fileURL: URL,
        text: String
    ) async -> [JavaSemanticToken]
    func notifyFilesChanged(_ fileURLs: [URL]) async
    func setBackgroundIndexingPaused(_ paused: Bool) async
    func rebuildIndex(repositoryID: RegisteredRepository.ID) async
    func clearUnusedCaches() async
    func shutdown() async
}

actor JavaLanguageEngine: JavaLanguageProviding {
    private struct SessionSlot: Sendable {
        let generation: UUID
        let session: any JavaLanguageServerSession
    }

    private struct IndexTaskSlot: Sendable {
        let generation: UUID
        let task: Task<Void, Never>
    }

    nonisolated let events: AsyncStream<JavaLanguageProviderEvent>
    private let eventContinuation: AsyncStream<JavaLanguageProviderEvent>.Continuation
    private let detector: any JavaProjectDetecting
    private let cacheStore: JavaLanguageCacheStore
    private let sessionFactory: JavaLanguageServerFactory
    private let backgroundDelay: Duration
    private let foregroundIdleTimeout: Duration

    private var settings: JavaIndexSettings
    private var descriptors: [RegisteredRepository.ID: JavaRepositoryDescriptor] = [:]
    private var states: [RegisteredRepository.ID: JavaRepositoryIndexState] = [:]
    private var sessions: [RegisteredRepository.ID: SessionSlot] = [:]
    private var sessionEventTasks: [RegisteredRepository.ID: Task<Void, Never>] = [:]
    private var indexTasks: [RegisteredRepository.ID: IndexTaskSlot] = [:]
    private var backgroundWakeTask: Task<Void, Never>?
    private var foregroundReleaseTask: Task<Void, Never>?
    private var foregroundRepositoryID: RegisteredRepository.ID?
    private var repositoryGitRevisions: [RegisteredRepository.ID: String] = [:]
    private var projectJavaHome: String?
    private var mavenUserSettingsFile: String?
    private var mavenLocalRepositoryURL: URL?
    private var isBackgroundIndexingPaused = false
    private var backgroundStartNotBefore = ContinuousClock.now

    init(
        settings: JavaIndexSettings = .default,
        detector: any JavaProjectDetecting = FileSystemJavaProjectDetector(),
        cacheStore: JavaLanguageCacheStore = JavaLanguageCacheStore(),
        backgroundDelay: Duration = .seconds(10),
        foregroundIdleTimeout: Duration = .seconds(300),
        sessionFactory: @escaping JavaLanguageServerFactory = { JDTLanguageServerSession() }
    ) {
        self.settings = settings
        self.detector = detector
        self.cacheStore = cacheStore
        self.backgroundDelay = backgroundDelay
        self.foregroundIdleTimeout = foregroundIdleTimeout
        self.sessionFactory = sessionFactory
        let pair = AsyncStream<JavaLanguageProviderEvent>.makeStream()
        events = pair.stream
        eventContinuation = pair.continuation
    }

    deinit {
        backgroundWakeTask?.cancel()
        foregroundReleaseTask?.cancel()
        indexTasks.values.forEach { $0.task.cancel() }
        sessionEventTasks.values.forEach { $0.cancel() }
        eventContinuation.finish()
    }

    func configure(_ settings: JavaIndexSettings) async {
        guard self.settings != settings else { return }
        self.settings = settings
        await stopAllSessions(requeueReady: true)
        trimCaches()
        schedule()
    }

    func updateWorkspace(
        workspaceURL: URL?,
        repositories: [RegisteredRepository],
        projectJavaHome: String?,
        mavenUserSettingsFile: String?,
        mavenLocalRepositoryURL: URL? = nil
    ) async {
        await stopAllSessions(requeueReady: false)
        descriptors = [:]
        states = [:]
        repositoryGitRevisions = [:]
        foregroundRepositoryID = nil
        self.projectJavaHome = projectJavaHome
        self.mavenUserSettingsFile = mavenUserSettingsFile
        self.mavenLocalRepositoryURL = mavenLocalRepositoryURL
        guard let workspaceURL else {
            publishSnapshot()
            return
        }

        let detector = self.detector
        let discovered = await Task.detached(priority: .utility) {
            let repositoryLocations = repositories.map { repository in
                let repositoryURL = repository.relativePath == "."
                    ? workspaceURL.standardizedFileURL
                    : workspaceURL.appendingPathComponent(repository.relativePath, isDirectory: true)
                        .standardizedFileURL
                return (repository: repository, url: repositoryURL)
            }
            return repositoryLocations.map { location -> JavaRepositoryDescriptor in
                let knownNestedRepositoryURLs = repositoryLocations.compactMap { candidate -> URL? in
                    guard candidate.url != location.url,
                          Self.isSameOrDescendant(candidate.url, of: location.url) else { return nil }
                    return candidate.url
                }
                let inspection = detector.inspectRepository(
                    at: location.url,
                    excluding: knownNestedRepositoryURLs
                )
                return JavaRepositoryDescriptor(
                    repositoryID: location.repository.id,
                    displayName: location.repository.name,
                    repositoryURL: location.url,
                    isJavaProject: inspection.isJavaProject,
                    nestedRepositoryURLs: inspection.nestedRepositoryURLs
                )
            }
        }.value

        for descriptor in discovered {
            descriptors[descriptor.id] = descriptor
            let gitState = Self.gitHeadState(repositoryURL: descriptor.repositoryURL)
            repositoryGitRevisions[descriptor.id] = gitState.revision
            let phase: JavaRepositoryIndexPhase
            if !descriptor.isJavaProject {
                try? cacheStore.removeCache(for: descriptor.repositoryURL)
                phase = .notRequired
            } else if cacheStore.hasReadyCache(
                for: descriptor.repositoryURL,
                scopeIdentifier: descriptor.cacheScopeIdentifier
            ) {
                phase = .ready
            } else {
                phase = .queued
            }
            states[descriptor.id] = JavaRepositoryIndexState(
                repositoryID: descriptor.id,
                displayName: descriptor.displayName,
                phase: phase,
                progress: nil,
                detail: nil,
                branchName: gitState.branchName,
                cacheBytes: cacheStore.bytes(for: descriptor.repositoryURL)
            )
        }
        backgroundStartNotBefore = ContinuousClock.now.advanced(by: backgroundDelay)
        publishSnapshot()
        schedule()
    }

    func prioritize(repositoryID: RegisteredRepository.ID) async {
        guard descriptors[repositoryID]?.isJavaProject == true else { return }
        foregroundRepositoryID = repositoryID
        resetForegroundIdleTimer(repositoryID: repositoryID)
        if sessions[repositoryID] == nil, indexTasks[repositoryID] == nil {
            states[repositoryID]?.phase = .queued
            states[repositoryID]?.detail = "等待加载 Java 索引"
        }
        if sessions.count >= settings.maximumJVMCount {
            await preemptBackgroundSession(except: repositoryID)
        }
        publishSnapshot()
        schedule(ignoringBackgroundDelay: true)
    }

    func navigationTargets(
        repositoryID: RegisteredRepository.ID,
        request: JavaNavigationRequest
    ) async -> [JavaNavigationTarget] {
        guard let session = await readySession(repositoryID: repositoryID) else { return [] }
        resetForegroundIdleTimer(repositoryID: repositoryID)
        do {
            return try await session.navigationTargets(for: request)
        } catch {
            states[repositoryID]?.detail = error.localizedDescription
            publishSnapshot()
            return []
        }
    }

    func searchSymbols(_ request: JavaSymbolSearchRequest) async -> [JavaNavigationTarget] {
        guard let session = await readySession(repositoryID: request.repositoryID) else { return [] }
        do {
            return try await session.searchSymbols(query: request.query, scope: request.scope)
        } catch {
            states[request.repositoryID]?.detail = error.localizedDescription
            publishSnapshot()
            return []
        }
    }

    func semanticTokens(
        repositoryID: RegisteredRepository.ID,
        fileURL: URL,
        text: String
    ) async -> [JavaSemanticToken] {
        guard let session = await readySession(repositoryID: repositoryID) else { return [] }
        do {
            return try await session.semanticTokens(fileURL: fileURL, text: text)
        } catch {
            return []
        }
    }

    func notifyFilesChanged(_ fileURLs: [URL]) async {
        guard !fileURLs.isEmpty else { return }
        for descriptor in descriptors.values where descriptor.isJavaProject {
            let relevant = fileURLs.filter(descriptor.containsOwnedFile)
            guard !relevant.isEmpty else { continue }
            var requiresProjectReload = relevant.contains {
                let name = $0.lastPathComponent
                return [
                    "pom.xml", "build.gradle", "build.gradle.kts",
                    "settings.gradle", "settings.gradle.kts", "HEAD"
                ].contains(name) || $0.path.contains("/.git/refs/")
            }
            let gitState = Self.gitHeadState(repositoryURL: descriptor.repositoryURL)
            if repositoryGitRevisions[descriptor.id] != gitState.revision {
                repositoryGitRevisions[descriptor.id] = gitState.revision
                states[descriptor.id]?.branchName = gitState.branchName
                requiresProjectReload = true
            }
            if let session = sessions[descriptor.id]?.session, !requiresProjectReload {
                await session.notifyFilesChanged(relevant)
                continue
            }
            if states[descriptor.id]?.phase != .notRequired {
                states[descriptor.id]?.phase = .stale
                states[descriptor.id]?.detail = "检测到外部文件或 Branch 变化"
                if requiresProjectReload {
                    indexTasks[descriptor.id]?.task.cancel()
                    indexTasks[descriptor.id] = nil
                    if let session = sessions.removeValue(forKey: descriptor.id)?.session {
                        sessionEventTasks.removeValue(forKey: descriptor.id)?.cancel()
                        await session.shutdown()
                    }
                }
            }
        }
        publishSnapshot()
        schedule()
    }

    func setBackgroundIndexingPaused(_ paused: Bool) async {
        guard isBackgroundIndexingPaused != paused else { return }
        isBackgroundIndexingPaused = paused
        if paused {
            for repositoryID in indexTasks.keys where repositoryID != foregroundRepositoryID {
                indexTasks[repositoryID]?.task.cancel()
            }
        } else {
            schedule()
        }
        publishSnapshot()
    }

    func rebuildIndex(repositoryID: RegisteredRepository.ID) async {
        guard let descriptor = descriptors[repositoryID], descriptor.isJavaProject else { return }
        indexTasks[repositoryID]?.task.cancel()
        indexTasks[repositoryID] = nil
        sessionEventTasks.removeValue(forKey: repositoryID)?.cancel()
        if let session = sessions.removeValue(forKey: repositoryID)?.session {
            await session.shutdown()
        }
        try? cacheStore.removeCache(for: descriptor.repositoryURL)
        states[repositoryID]?.phase = .queued
        states[repositoryID]?.progress = nil
        states[repositoryID]?.detail = "等待重建 Java 索引"
        publishSnapshot()
        schedule(ignoringBackgroundDelay: repositoryID == foregroundRepositoryID)
    }

    func clearUnusedCaches() async {
        let activeURLs = Set(sessions.keys.compactMap { descriptors[$0]?.repositoryURL })
        _ = cacheStore.trim(to: 0, excluding: activeURLs)
        refreshCacheSizes()
        publishSnapshot()
    }

    func shutdown() async {
        await stopAllSessions(requeueReady: false)
        descriptors = [:]
        states = [:]
        repositoryGitRevisions = [:]
        foregroundRepositoryID = nil
        publishSnapshot()
    }

    private func schedule(ignoringBackgroundDelay: Bool = false) {
        backgroundWakeTask?.cancel()
        backgroundWakeTask = nil
        let occupiedRepositoryIDs = Set(sessions.keys).union(indexTasks.keys)
        let availableSlots = settings.maximumJVMCount - occupiedRepositoryIDs.count
        guard availableSlots > 0 else { return }
        let candidates = states.values.filter {
            ($0.phase == .queued || $0.phase == .stale)
                && indexTasks[$0.repositoryID] == nil
                && sessions[$0.repositoryID] == nil
                && (!isBackgroundIndexingPaused || $0.repositoryID == foregroundRepositoryID)
        }.sorted { lhs, rhs in
            if lhs.repositoryID == foregroundRepositoryID { return true }
            if rhs.repositoryID == foregroundRepositoryID { return false }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }
        guard !candidates.isEmpty else { return }

        let shouldDelay = !ignoringBackgroundDelay
            && foregroundRepositoryID == nil
            && ContinuousClock.now < backgroundStartNotBefore
        if shouldDelay {
            let deadline = backgroundStartNotBefore
            backgroundWakeTask = Task { [weak self] in
                try? await Task.sleep(until: deadline, clock: .continuous)
                await self?.wakeBackgroundScheduler()
            }
            return
        }

        for state in candidates.prefix(availableSlots) {
            let repositoryID = state.repositoryID
            let generation = UUID()
            states[repositoryID]?.phase = .starting
            states[repositoryID]?.progress = nil
            states[repositoryID]?.detail = "正在启动 Java language server"
            let task = Task { [weak self] in
                guard let self else { return }
                await self.indexRepository(repositoryID, generation: generation)
            }
            indexTasks[repositoryID] = IndexTaskSlot(generation: generation, task: task)
        }
        publishSnapshot()
    }

    private func readySession(
        repositoryID: RegisteredRepository.ID
    ) async -> (any JavaLanguageServerSession)? {
        await prioritize(repositoryID: repositoryID)
        if states[repositoryID]?.phase == .ready,
           let session = sessions[repositoryID]?.session {
            return session
        }
        guard let startupTask = indexTasks[repositoryID]?.task else { return nil }
        await startupTask.value
        guard states[repositoryID]?.phase == .ready else { return nil }
        return sessions[repositoryID]?.session
    }

    private func wakeBackgroundScheduler() {
        backgroundWakeTask = nil
        schedule(ignoringBackgroundDelay: true)
    }

    private func indexRepository(
        _ repositoryID: RegisteredRepository.ID,
        generation: UUID
    ) async {
        guard let descriptor = descriptors[repositoryID] else {
            finishIndexTask(repositoryID, generation: generation)
            return
        }
        let session = sessionFactory()
        guard indexTasks[repositoryID]?.generation == generation else { return }
        sessions[repositoryID] = SessionSlot(generation: generation, session: session)
        let events = session.events
        sessionEventTasks[repositoryID] = Task { [weak self] in
            for await event in events {
                await self?.handleSessionEvent(
                    event,
                    repositoryID: repositoryID,
                    generation: generation
                )
            }
        }
        do {
            let dataDirectoryURL = try cacheStore.dataDirectory(
                for: descriptor.repositoryURL,
                scopeIdentifier: descriptor.cacheScopeIdentifier
            )
            try Task.checkCancellation()
            try await session.start(
                configuration: JavaLanguageServerConfiguration(
                    repository: descriptor,
                    dataDirectoryURL: dataDirectoryURL,
                    settings: settings,
                    projectJavaHome: projectJavaHome,
                    mavenUserSettingsFile: mavenUserSettingsFile,
                    mavenLocalRepositoryURL: mavenLocalRepositoryURL
                )
            )
            try Task.checkCancellation()
            guard isCurrentGeneration(generation, for: repositoryID) else {
                throw CancellationError()
            }
            states[repositoryID]?.phase = .indexing
            states[repositoryID]?.detail = "正在导入 Maven 项目"
            publishSnapshot()
            try await session.waitUntilReady(timeout: .seconds(600))
            try Task.checkCancellation()
            guard isCurrentGeneration(generation, for: repositoryID) else {
                throw CancellationError()
            }
            try cacheStore.markReady(
                repositoryURL: descriptor.repositoryURL,
                scopeIdentifier: descriptor.cacheScopeIdentifier
            )
            states[repositoryID]?.phase = .ready
            states[repositoryID]?.progress = 1
            states[repositoryID]?.detail = "Java 索引已就绪"
            states[repositoryID]?.cacheBytes = cacheStore.bytes(for: descriptor.repositoryURL)
            cacheStore.touch(repositoryURL: descriptor.repositoryURL)
            publishSnapshot()
        } catch is CancellationError {
            if isCurrentGeneration(generation, for: repositoryID) {
                states[repositoryID]?.phase = .queued
                states[repositoryID]?.progress = nil
                states[repositoryID]?.detail = "等待后台索引"
            }
            await session.shutdown()
            removeSession(repositoryID, generation: generation)
        } catch {
            if isCurrentGeneration(generation, for: repositoryID) {
                states[repositoryID]?.phase = .failed
                states[repositoryID]?.progress = nil
                states[repositoryID]?.detail = error.localizedDescription
            }
            await session.shutdown()
            removeSession(repositoryID, generation: generation)
            publishSnapshot()
        }
        finishIndexTask(repositoryID, generation: generation)
        if repositoryID != foregroundRepositoryID,
           sessions[repositoryID]?.generation == generation,
           let slot = sessions.removeValue(forKey: repositoryID) {
            sessionEventTasks.removeValue(forKey: repositoryID)?.cancel()
            await slot.session.shutdown()
        }
        trimCaches()
        schedule(ignoringBackgroundDelay: true)
    }

    private func finishIndexTask(_ repositoryID: RegisteredRepository.ID, generation: UUID) {
        guard indexTasks[repositoryID]?.generation == generation else { return }
        indexTasks[repositoryID] = nil
    }

    private func handleSessionEvent(
        _ event: JavaLanguageServerEvent,
        repositoryID: RegisteredRepository.ID,
        generation: UUID
    ) {
        guard states[repositoryID] != nil,
              sessions[repositoryID]?.generation == generation else { return }
        switch event {
        case .status(let type, let message):
            if type == "Error" {
                states[repositoryID]?.detail = message ?? "Java language server error"
            } else if let message, !message.isEmpty {
                states[repositoryID]?.detail = message
            }
        case .progress(let fraction, let detail):
            guard let phase = states[repositoryID]?.phase,
                  phase == .starting || phase == .indexing else { break }
            states[repositoryID]?.phase = .indexing
            states[repositoryID]?.progress = fraction
            if let detail, !detail.isEmpty { states[repositoryID]?.detail = detail }
        case .ready:
            break
        case .log(let message):
            if states[repositoryID]?.phase == .failed {
                states[repositoryID]?.detail = message
            }
        case .terminated(let detail):
            if indexTasks[repositoryID] != nil,
               states[repositoryID]?.phase != .failed {
                states[repositoryID]?.phase = .failed
                states[repositoryID]?.detail = detail ?? "Java language server exited"
            } else if indexTasks[repositoryID] == nil {
                // A retained ready/warm session can exit after indexing has completed.
                // Remove it immediately so navigation cannot keep using a dead server.
                sessions[repositoryID] = nil
                sessionEventTasks.removeValue(forKey: repositoryID)?.cancel()
                if states[repositoryID]?.phase != .notRequired {
                    states[repositoryID]?.phase = .failed
                    states[repositoryID]?.progress = nil
                    states[repositoryID]?.detail = detail ?? "Java language server exited"
                }
            }
        }
        publishSnapshot()
    }

    private func preemptBackgroundSession(except repositoryID: RegisteredRepository.ID) async {
        guard let victim = sessions.keys.first(where: { $0 != repositoryID && $0 != foregroundRepositoryID })
                ?? sessions.keys.first(where: { $0 != repositoryID }) else { return }
        indexTasks[victim]?.task.cancel()
        indexTasks[victim] = nil
        sessionEventTasks.removeValue(forKey: victim)?.cancel()
        if let session = sessions.removeValue(forKey: victim)?.session {
            await session.shutdown()
        }
        if states[victim]?.phase != .ready {
            states[victim]?.phase = .queued
            states[victim]?.detail = "等待后台索引"
        }
    }

    private func resetForegroundIdleTimer(repositoryID: RegisteredRepository.ID) {
        foregroundReleaseTask?.cancel()
        foregroundReleaseTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.foregroundIdleTimeout ?? .seconds(300))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.releaseForegroundIfIdle(repositoryID: repositoryID)
        }
    }

    private func releaseForegroundIfIdle(repositoryID: RegisteredRepository.ID) async {
        guard foregroundRepositoryID == repositoryID else { return }
        if indexTasks[repositoryID] != nil {
            resetForegroundIdleTimer(repositoryID: repositoryID)
            return
        }
        foregroundRepositoryID = nil
        foregroundReleaseTask = nil
        if let session = sessions.removeValue(forKey: repositoryID)?.session {
            sessionEventTasks.removeValue(forKey: repositoryID)?.cancel()
            await session.shutdown()
        }
        publishSnapshot()
        schedule(ignoringBackgroundDelay: true)
    }

    private func stopAllSessions(requeueReady: Bool) async {
        backgroundWakeTask?.cancel()
        backgroundWakeTask = nil
        foregroundReleaseTask?.cancel()
        foregroundReleaseTask = nil
        let tasks = Array(indexTasks.values.map(\.task))
        tasks.forEach { $0.cancel() }
        indexTasks = [:]
        sessionEventTasks.values.forEach { $0.cancel() }
        sessionEventTasks = [:]
        let existingSessions = sessions
        sessions = [:]
        for slot in existingSessions.values {
            await slot.session.shutdown()
        }
        if requeueReady {
            for id in states.keys where states[id]?.phase != .notRequired {
                states[id]?.phase = .queued
                states[id]?.progress = nil
            }
        }
    }

    private func trimCaches() {
        let activeURLs = Set(sessions.keys.compactMap { descriptors[$0]?.repositoryURL })
        let maximumBytes = Int64(settings.cacheLimitGigabytes) * 1_024 * 1_024 * 1_024
        _ = cacheStore.trim(to: maximumBytes, excluding: activeURLs)
        refreshCacheSizes()
        publishSnapshot()
    }

    private func refreshCacheSizes() {
        for descriptor in descriptors.values {
            states[descriptor.id]?.cacheBytes = cacheStore.bytes(for: descriptor.repositoryURL)
        }
    }

    private func isCurrentGeneration(
        _ generation: UUID,
        for repositoryID: RegisteredRepository.ID
    ) -> Bool {
        indexTasks[repositoryID]?.generation == generation
            && sessions[repositoryID]?.generation == generation
    }

    private func removeSession(_ repositoryID: RegisteredRepository.ID, generation: UUID) {
        guard sessions[repositoryID]?.generation == generation else { return }
        sessions[repositoryID] = nil
        sessionEventTasks.removeValue(forKey: repositoryID)?.cancel()
    }

    private func publishSnapshot() {
        let ordered = states.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
        eventContinuation.yield(
            .snapshot(
                JavaIndexSnapshot(
                    repositories: ordered,
                    activeRepositoryID: foregroundRepositoryID,
                    runningJVMCount: sessions.count,
                    cacheBytes: cacheStore.totalBytes(),
                    isBackgroundIndexingPaused: isBackgroundIndexingPaused
                )
            )
        )
    }

    private static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        if candidate == root { return true }
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return candidate.path.hasPrefix(rootPath)
    }

    private static func gitHeadState(repositoryURL: URL) -> (branchName: String?, revision: String) {
        let fileManager = FileManager.default
        let dotGitURL = repositoryURL.appendingPathComponent(".git")
        let gitDirectoryURL: URL
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            gitDirectoryURL = dotGitURL
        } else if let contents = try? String(contentsOf: dotGitURL, encoding: .utf8),
                  contents.hasPrefix("gitdir:") {
            let path = contents.dropFirst("gitdir:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let candidate = URL(fileURLWithPath: path, relativeTo: repositoryURL)
            gitDirectoryURL = candidate.standardizedFileURL
        } else {
            return (nil, "")
        }

        let head = ((try? String(
            contentsOf: gitDirectoryURL.appendingPathComponent("HEAD"),
            encoding: .utf8
        )) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.hasPrefix("ref:") else {
            return (head.isEmpty ? nil : "detached", head)
        }
        let reference = head.dropFirst("ref:".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let revision = ((try? String(
            contentsOf: gitDirectoryURL.appendingPathComponent(reference),
            encoding: .utf8
        )) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let branchName = reference.hasPrefix("refs/heads/")
            ? String(reference.dropFirst("refs/heads/".count))
            : reference
        return (branchName, "\(head)|\(revision)")
    }
}
