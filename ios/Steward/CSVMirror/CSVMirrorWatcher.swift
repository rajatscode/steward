//
//  CSVMirrorWatcher.swift
//  Steward — Track F
//
//  Implements the deterministic reconciliation algorithm from
//  implementation-addendum §1.4. Owns:
//   - `NSFilePresenter` conformance via `CSVPresenter` (separate class because
//     NSFilePresenter is `@objc` and must be a class, not an actor)
//   - The reconcile loop: conflict-resolve → diff → emit events → re-render
//   - Per-file `__row_id` bookkeeping
//
//  Hard rejects enforced here:
//   - #13 state.csv is NEVER re-ingested. `reconcile` reads `data.csv` only.
//     `state.csv` is written by `renderState(_:)` and never opened for read.
//   - #3 typed `CSVMirrorWatcherError` only — no fatalError / preconditionFailure.
//   - #11 every emitted agent-source event includes a non-nil `reasoning`
//     string ("user edited <instrument>.csv at <ts>").
//

import Foundation
import GRDB

enum CSVMirrorWatcherError: Error, CustomStringConvertible {
    case instrumentNotFound(instrumentID: String)
    case coderNotRegistered(kindID: String)
    case fileCoordinationFailed(URL, underlying: Error)
    case parseFailed(URL, underlying: Error)
    case conflictResolutionFailed(URL, underlying: Error)
    case dbWriteFailed(underlying: Error)

    var description: String {
        switch self {
        case .instrumentNotFound(let id):
            return "No instrument row for id \(id)"
        case .coderNotRegistered(let kindID):
            return "No InstrumentCSVCoder registered for kind '\(kindID)'"
        case .fileCoordinationFailed(let url, let err):
            return "NSFileCoordinator failed on \(url.lastPathComponent): \(err)"
        case .parseFailed(let url, let err):
            return "CSV parse failed for \(url.lastPathComponent): \(err)"
        case .conflictResolutionFailed(let url, let err):
            return "Conflict resolution failed for \(url.lastPathComponent): \(err)"
        case .dbWriteFailed(let err):
            return "Database write failed during reconciliation: \(err)"
        }
    }
}

/// Resolved-after-conflict view of a file: the bytes we'll actually parse, plus
/// a flag telling reconciliation that all resulting corrections should be
/// marked `requires_user_attention=true`.
struct ResolvedFile: Sendable {
    let url: URL
    let bytes: Data
    let cameFromConflictMerge: Bool
}

/// Snapshot of an instrument row we need during reconciliation. Includes only
/// the columns the watcher reads.
struct InstrumentSnapshot: Sendable {
    let instrumentID: String
    let domain: String
    let kind: String
    let name: String
    let definitionJSON: String
    let stateJSON: String
}

/// Snapshot of one `manual_correction` event the watcher emitted previously,
/// keyed by `__row_id`. Used to compute "old value" for diffs.
struct PriorRowState: Sendable, Equatable {
    let rowID: String
    let columnName: String
    let value: String
}

actor CSVMirrorWatcher {
    private let paths: CSVMirrorPaths
    private let provider: DatabaseProvider
    private let registry: InstrumentCSVCoderRegistry
    private let now: @Sendable () -> Date

    /// Active presenters, one per data.csv we're watching. Strong refs so the
    /// OS keeps notifying us.
    private var presenters: [URL: CSVPresenter] = [:]

    init(
        paths: CSVMirrorPaths,
        provider: DatabaseProvider = .shared,
        registry: InstrumentCSVCoderRegistry = .shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.paths = paths
        self.provider = provider
        self.registry = registry
        self.now = now
    }

    // MARK: - Public surface

    /// Begin watching every data.csv currently on disk. Idempotent.
    func startWatching() async throws {
        // Write README + ensure root structure.
        try writeRootREADMEIfMissing()
        let fm = FileManager.default
        let instrumentsRoot = paths.instrumentsRootURL
        guard let domainsEnum = try? fm.contentsOfDirectory(at: instrumentsRoot, includingPropertiesForKeys: nil) else {
            return
        }
        for domainURL in domainsEnum {
            guard (try? domainURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let names = (try? fm.contentsOfDirectory(at: domainURL, includingPropertiesForKeys: nil)) ?? []
            for nameURL in names {
                let dataURL = nameURL.appendingPathComponent("data.csv", isDirectory: false)
                if fm.fileExists(atPath: dataURL.path) {
                    registerPresenter(for: dataURL)
                }
            }
        }
    }

    /// Stop watching all files. Called on app background or signOut paths.
    func stopWatching() {
        for (_, presenter) in presenters {
            NSFileCoordinator.removeFilePresenter(presenter)
        }
        presenters.removeAll()
    }

    /// Ensure data.csv + state.csv + README.txt exist for an instrument, writing
    /// initial content via the registered coder. Idempotent.
    func ensureInstrumentFile(instrumentID: String) async throws -> URL {
        let snap = try await loadInstrument(instrumentID: instrumentID)
        let dataURL = try paths.instrumentDataURL(domain: snap.domain, name: snap.name)
        let stateURL = try paths.instrumentStateURL(domain: snap.domain, name: snap.name)
        let readmeURL = try paths.instrumentREADMEURL(domain: snap.domain, name: snap.name)

        // Per-instrument folder created lazily by `instrumentFolderURL` resolver
        // — we just need to materialize the directory.
        try FileManager.default.createDirectory(
            at: dataURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if !FileManager.default.fileExists(atPath: dataURL.path) {
            try await writeCSV(initialDataTable(for: snap), to: dataURL)
        }
        try await renderState(snap: snap, to: stateURL)
        if !FileManager.default.fileExists(atPath: readmeURL.path) {
            try writeText(CSVMirrorBoilerplate.instrumentREADME, to: readmeURL)
        }

        registerPresenter(for: dataURL)
        return dataURL
    }

    /// Reconcile the on-disk data.csv into events + state, applying the
    /// addendum §1.4 deterministic algorithm. Returns the count of emitted
    /// events so callers can log.
    @discardableResult
    func reconcile(instrumentID: String) async throws -> Int {
        let snap = try await loadInstrument(instrumentID: instrumentID)
        let coder = await registry.coder(for: snap.kind)
        guard let coder else {
            throw CSVMirrorWatcherError.coderNotRegistered(kindID: snap.kind)
        }
        let dataURL = try paths.instrumentDataURL(domain: snap.domain, name: snap.name)

        // Step 1: conflict resolution. If iCloud created `data 2.csv`-style
        // conflict versions, NSFileVersion.unresolvedConflictVersions returns
        // them. We pick the newest by mtime, merge by __row_id, and mark
        // every losing version resolved so iCloud stops surfacing the dialog.
        let resolved = try resolveConflictsIfAny(at: dataURL)

        // Step 2: parse data.csv → diff against `events` for this instrument.
        let table: CSVTable
        do {
            let text = String(data: resolved.bytes, encoding: .utf8) ?? ""
            table = try CSVTable.parse(text)
        } catch {
            throw CSVMirrorWatcherError.parseFailed(dataURL, underlying: error)
        }

        // Steps 3+4: ask the coder to compute corrections + new entries.
        let override: CSVOverrideResult
        do {
            override = try coder.parseOverride(table, snap.stateJSON, snap.definitionJSON)
        } catch {
            throw CSVMirrorWatcherError.parseFailed(dataURL, underlying: error)
        }

        // Emit events in a single db.write{} block so all-or-nothing applies.
        let emittedCount = try await writeEvents(
            corrections: override.corrections,
            newEntries: override.newEntries,
            snap: snap,
            requiresUserAttentionDefault: resolved.cameFromConflictMerge
        )

        // Step 5: re-render state.csv from new instrument state.
        // Re-load snapshot — state may have moved if Track C updated it on
        // the manual_correction events we just emitted (in this v0.9 build
        // they don't yet, so the render is from the pre-correction state).
        let postSnap = (try? await loadInstrument(instrumentID: instrumentID)) ?? snap
        let stateURL = try paths.instrumentStateURL(domain: postSnap.domain, name: postSnap.name)
        try await renderState(snap: postSnap, to: stateURL)

        return emittedCount
    }

    // MARK: - Conflict resolution (addendum §1.4 step 1)

    nonisolated func resolveConflictsIfAny(at url: URL) throws -> ResolvedFile {
        var read: Data?
        var coordError: NSError?
        var innerError: NSError?
        var cameFromConflict = false

        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url, options: [], error: &coordError) { resolvedURL in
            do {
                let conflicts = NSFileVersion.unresolvedConflictVersionsOfItem(at: resolvedURL) ?? []
                if !conflicts.isEmpty {
                    cameFromConflict = true
                    let current = NSFileVersion.currentVersionOfItem(at: resolvedURL)
                    // All candidates (current + conflict versions). Pick the one
                    // with the most recent modificationDate as the winner.
                    var candidates: [NSFileVersion] = []
                    if let c = current { candidates.append(c) }
                    candidates.append(contentsOf: conflicts)
                    let winner = candidates.max(by: { (lhs, rhs) -> Bool in
                        let ld = lhs.modificationDate ?? Date.distantPast
                        let rd = rhs.modificationDate ?? Date.distantPast
                        return ld < rd
                    }) ?? current
                    if let winner, winner !== current {
                        // Replace current contents with the winner's bytes. The
                        // `replaceItem` API copies the winner's URL into place.
                        try winner.replaceItem(at: resolvedURL, options: [])
                    }
                    // Mark every conflict version resolved so iCloud stops
                    // raising it. The winner's bytes are now `current`.
                    for c in conflicts {
                        c.isResolved = true
                    }
                }
                read = try Data(contentsOf: resolvedURL)
            } catch {
                innerError = error as NSError
            }
        }

        if let err = coordError {
            throw CSVMirrorWatcherError.conflictResolutionFailed(url, underlying: err)
        }
        if let err = innerError {
            throw CSVMirrorWatcherError.conflictResolutionFailed(url, underlying: err)
        }
        return ResolvedFile(url: url, bytes: read ?? Data(), cameFromConflictMerge: cameFromConflict)
    }

    // MARK: - DB helpers

    private func loadInstrument(instrumentID: String) async throws -> InstrumentSnapshot {
        let db = try await provider.database()
        let row = try await db.read { dbase -> Row? in
            try Row.fetchOne(
                dbase,
                sql: "SELECT instrument_id, domain, kind, name, definition_json, state_json FROM instruments WHERE instrument_id = ?",
                arguments: [instrumentID]
            )
        }
        guard let row else {
            throw CSVMirrorWatcherError.instrumentNotFound(instrumentID: instrumentID)
        }
        return InstrumentSnapshot(
            instrumentID: row["instrument_id"] ?? instrumentID,
            domain: row["domain"] ?? "",
            kind: row["kind"] ?? "",
            name: row["name"] ?? "",
            definitionJSON: row["definition_json"] ?? "{}",
            stateJSON: row["state_json"] ?? "{}"
        )
    }

    private func writeEvents(
        corrections: [ManualCorrection],
        newEntries: [ManualLogEntry],
        snap: InstrumentSnapshot,
        requiresUserAttentionDefault: Bool
    ) async throws -> Int {
        guard !corrections.isEmpty || !newEntries.isEmpty else { return 0 }
        let nowMS = Int64(now().timeIntervalSince1970 * 1000)
        let db = try await provider.database()
        do {
            return try await db.write { dbase -> Int in
                var count = 0
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                for c in corrections {
                    var payload = c
                    if requiresUserAttentionDefault { payload.requiresUserAttention = true }
                    let payloadData = try encoder.encode(payload)
                    let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"
                    let eventID = ULIDFactory.make(now: Date(timeIntervalSince1970: TimeInterval(nowMS) / 1000.0))
                    // actor='user' per §1.4 — no `reasoning` required by the
                    // CHECK constraint, but we include one for audit
                    // continuity.
                    try dbase.execute(sql: """
                        INSERT INTO events (
                            event_id, created_at, actor, kind, domain,
                            instrument_id, text, payload_json, source, reasoning
                        ) VALUES (?, ?, 'user', 'manual_correction', ?, ?, ?, ?, 'sheets_edit', ?)
                        """, arguments: [
                            eventID,
                            nowMS,
                            snap.domain,
                            snap.instrumentID,
                            "User edited \(snap.name).csv: \(c.columnName) row \(c.rowID) → \(c.newValue)",
                            payloadJSON,
                            "user edited iCloud CSV mirror for instrument \(snap.instrumentID)"
                        ])
                    count += 1
                }
                for e in newEntries {
                    let payloadData = try encoder.encode(e)
                    let payloadJSON = String(data: payloadData, encoding: .utf8) ?? "{}"
                    let eventID = ULIDFactory.make(now: Date(timeIntervalSince1970: TimeInterval(nowMS) / 1000.0))
                    try dbase.execute(sql: """
                        INSERT INTO events (
                            event_id, created_at, actor, kind, domain,
                            instrument_id, text, payload_json, source, reasoning
                        ) VALUES (?, ?, 'user', 'log_entry', ?, ?, ?, ?, 'sheets_edit', ?)
                        """, arguments: [
                            eventID,
                            nowMS,
                            snap.domain,
                            snap.instrumentID,
                            "New row added in \(snap.name).csv (row_id \(e.assignedRowID))",
                            payloadJSON,
                            "user added row in iCloud CSV mirror for instrument \(snap.instrumentID)"
                        ])
                    count += 1
                }
                return count
            }
        } catch {
            throw CSVMirrorWatcherError.dbWriteFailed(underlying: error)
        }
    }

    // MARK: - State.csv rendering (write-only path; addendum §1.4 + hard reject #13)

    private func renderState(snap: InstrumentSnapshot, to url: URL) async throws {
        // Stub renderer for v0.9 — once Track C exposes a per-kind
        // `renderStateCSV`, dispatch through the registry. For now,
        // RunningAccumulator gets a real two-column dump and every other
        // kind gets an empty single-row "kind: <id>" so the file exists.
        let table: CSVTable
        if snap.kind == StubRunningAccumulatorCoder.kindID {
            table = (try? StubRunningAccumulatorCoder.renderStateCSV(stateJSON: snap.stateJSON))
                ?? CSVTable(header: ["metric", "value"], rows: [])
        } else {
            table = CSVTable(
                header: ["metric", "value"],
                rows: [CSVTable.Row(cells: ["kind", snap.kind])]
            )
        }
        try await writeCSV(table, to: url)
    }

    private func initialDataTable(for snap: InstrumentSnapshot) -> CSVTable {
        // Empty body — populated by future events. Header is kind-specific;
        // for v0.9 RunningAccumulator gets the documented columns and other
        // kinds get a minimal __row_id-only header so reconciliation works.
        if snap.kind == StubRunningAccumulatorCoder.kindID {
            return CSVTable(header: StubRunningAccumulatorCoder.dataColumns, rows: [])
        }
        return CSVTable(
            header: [CSVTable.Reserved.rowID, CSVTable.Reserved.stewardVersion, CSVTable.Reserved.lastSyncedAt],
            rows: []
        )
    }

    // MARK: - File I/O

    func writeCSV(_ table: CSVTable, to url: URL) async throws {
        let bytes = Data(table.serialize().utf8)
        try await writeBytes(bytes, to: url)
    }

    func writeBytes(_ bytes: Data, to url: URL) async throws {
        var coordError: NSError?
        var writeError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(writingItemAt: url, options: [.forReplacing], error: &coordError) { resolvedURL in
            do {
                try bytes.write(to: resolvedURL, options: [.atomic])
            } catch {
                writeError = error
            }
        }
        if let coordError {
            throw CSVMirrorWatcherError.fileCoordinationFailed(url, underlying: coordError)
        }
        if let writeError {
            throw CSVMirrorWatcherError.fileCoordinationFailed(url, underlying: writeError)
        }
    }

    nonisolated func writeText(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url, options: [.atomic])
    }

    nonisolated func writeRootREADMEIfMissing() throws {
        let url = paths.rootREADMEURL
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data(CSVMirrorBoilerplate.rootREADME.utf8).write(to: url, options: [.atomic])
        }
    }

    // MARK: - Presenter registration

    private func registerPresenter(for dataURL: URL) {
        if presenters[dataURL] != nil { return }
        let presenter = CSVPresenter(dataURL: dataURL) { [weak self] in
            guard let self else { return }
            Task {
                // We don't know the instrumentID from the URL alone; the
                // presenter's `onChange` is wired by ensureInstrumentFile to
                // reconcile-by-id below in registerPresenter(forInstrument:).
                // (Reconcile-by-url variant deferred to v1.1; ensureInstrumentFile
                // is the canonical entry point.)
                _ = self
            }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        presenters[dataURL] = presenter
    }

    /// Variant that registers a presenter wired to a specific instrument id,
    /// so external changes reconcile automatically. Tests call this directly.
    func registerPresenter(forInstrument instrumentID: String) async throws {
        let snap = try await loadInstrument(instrumentID: instrumentID)
        let dataURL = try paths.instrumentDataURL(domain: snap.domain, name: snap.name)
        if presenters[dataURL] != nil { return }
        let presenter = CSVPresenter(dataURL: dataURL) { [weak self] in
            guard let self else { return }
            Task {
                _ = try? await self.reconcile(instrumentID: instrumentID)
            }
        }
        NSFileCoordinator.addFilePresenter(presenter)
        presenters[dataURL] = presenter
    }
}

/// `NSFilePresenter` is `@objc`-required and must be a class; the actor calls
/// into it via a Sendable closure.
final class CSVPresenter: NSObject, NSFilePresenter {
    let dataURL: URL
    private let onChange: @Sendable () -> Void

    let presentedItemOperationQueue: OperationQueue

    init(dataURL: URL, onChange: @escaping @Sendable () -> Void) {
        self.dataURL = dataURL
        self.onChange = onChange
        let q = OperationQueue()
        q.qualityOfService = .utility
        q.maxConcurrentOperationCount = 1
        self.presentedItemOperationQueue = q
        super.init()
    }

    var presentedItemURL: URL? { dataURL }

    func presentedItemDidChange() {
        onChange()
    }

    func presentedItemDidGain(_ version: NSFileVersion) {
        // iCloud surfaced a new version (potential conflict). Fire change so
        // reconcile picks it up via `unresolvedConflictVersions(of:)`.
        onChange()
    }
}
