//
//  SettingsStore.swift
//  Steward
//
//  Serialized read/write surface for the single-row `settings` table.
//  Addendum §4 hard reject #16: all settings mutations must go through one
//  actor so concurrent tool calls can't lose updates. Pods B / D / F all
//  mutate disjoint fields; the actor lets them do so safely.
//
//  Wire-format note: the on-disk JSON is snake_case per spec §5. We
//  use `JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase` and the
//  matching encoder strategy so Swift sees idiomatic camelCase. Nested
//  fields like `quietHours.start` / `quietHours.end` stay lowercase already.
//

import Foundation
import GRDB

/// Strongly-typed mirror of the JSON blob in `settings.settings_json`.
struct Settings: Codable, Sendable, Equatable {
    struct QuietHours: Codable, Sendable, Equatable {
        /// "HH:mm" wall-clock string, autoupdating local timezone.
        var start: String
        var end: String
    }

    var quietHours: QuietHours
    /// "HH:mm" wall-clock string for the daily morning brief.
    var morningBriefTime: String
    var maxProactiveNotificationsPerDay: Int
    var minNotificationGapMinutes: Int
    var mercyModeUntil: Date?
    var pauseUntil: Date?
    var csvMirrorEnabled: Bool
    var icloudDriveFolder: String
    var voiceCaptureEnabled: Bool
    var defaultAgentTemperature: Double
}

enum SettingsStoreError: Error, CustomStringConvertible {
    case rowMissing
    case decodingFailed(underlying: Error)
    case encodingFailed(underlying: Error)

    var description: String {
        switch self {
        case .rowMissing:
            return "settings table has no row with id=1 (migration seed missing?)"
        case .decodingFailed(let underlying):
            return "Settings JSON decode failed: \(underlying)"
        case .encodingFailed(let underlying):
            return "Settings JSON encode failed: \(underlying)"
        }
    }
}

/// Actor-serialized accessor for the `settings` row.
///
/// `load()` returns the cached value if present, decoding from disk on first
/// access. `update(_:)` performs a read-mutate-write inside a single
/// `db.write { }` block and refreshes the cache. Tests use
/// `invalidateCache()` to force a re-read.
///
/// Hard rule (addendum §1.11): raw `UPDATE settings SET ...` outside this
/// file is a §4 hard reject. Every other pod (B / D / F) goes through
/// `SettingsStore.shared.update`.
actor SettingsStore {
    static let shared = SettingsStore()

    private let provider: DatabaseProvider
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var cached: Settings?

    init(provider: DatabaseProvider = .shared) {
        self.provider = provider

        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec

        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        enc.dateEncodingStrategy = .iso8601
        // Stable on-disk ordering helps the iCloud CSV mirror present
        // diff-able settings.json snapshots later (Pod F may render this).
        // Locked in addendum §1.11.
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc
    }

    /// Returns the current settings. Cached after first read.
    func load() async throws -> Settings {
        if let cached { return cached }
        let db = try await provider.database()
        let dec = self.decoder
        let loaded = try await db.read { dbase in
            try Self.fetch(db: dbase, decoder: dec)
        }
        cached = loaded
        return loaded
    }

    /// Atomic read-modify-write. Mutation runs inside a single `db.write { }`
    /// block; the cache is refreshed and the new value returned. Two
    /// concurrent `update` calls serialize on the actor — last-writer wins on
    /// overlapping fields, but neither call sees a torn read.
    @discardableResult
    func update(_ mutate: @escaping @Sendable (inout Settings) -> Void) async throws -> Settings {
        let db = try await provider.database()
        let dec = self.decoder
        let enc = self.encoder
        let updated = try await db.write { dbase in
            var current = try Self.fetch(db: dbase, decoder: dec)
            mutate(&current)
            let data: Data
            do {
                data = try enc.encode(current)
            } catch {
                throw SettingsStoreError.encodingFailed(underlying: error)
            }
            guard let json = String(data: data, encoding: .utf8) else {
                throw SettingsStoreError.encodingFailed(
                    underlying: NSError(domain: "Steward.SettingsStore", code: 1,
                                        userInfo: [NSLocalizedDescriptionKey: "UTF-8 encode failed"])
                )
            }
            try dbase.execute(
                sql: "UPDATE settings SET settings_json = ? WHERE id = 1",
                arguments: [json]
            )
            return current
        }
        cached = updated
        return updated
    }

    /// Test seam — discards the cache so the next `load` re-reads from disk.
    func invalidateCache() {
        cached = nil
    }

    // MARK: - Private

    private static func fetch(db: Database, decoder: JSONDecoder) throws -> Settings {
        guard let json = try String.fetchOne(
            db,
            sql: "SELECT settings_json FROM settings WHERE id = 1"
        ) else {
            throw SettingsStoreError.rowMissing
        }
        guard let data = json.data(using: .utf8) else {
            throw SettingsStoreError.decodingFailed(
                underlying: NSError(domain: "Steward.SettingsStore", code: 2,
                                    userInfo: [NSLocalizedDescriptionKey: "UTF-8 decode failed"])
            )
        }
        do {
            return try decoder.decode(Settings.self, from: data)
        } catch {
            throw SettingsStoreError.decodingFailed(underlying: error)
        }
    }
}
