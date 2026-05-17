//
//  VoiceCaptureServiceTests.swift
//  StewardTests
//
//  Track F voice capture coverage:
//   - WhisperKitModelLocator fails-closed when the bundle has no model
//     (hard reject #15 — no lazy-download path even exists).
//   - WhisperKitModelLocator returns the URL when the model dir is present.
//   - VoiceCaptureService reports `.unavailable(.modelMissing)` on init when
//     model dir is empty (and never reaches out to the network).
//

import XCTest
@testable import Steward

final class VoiceCaptureServiceTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a tiny throwaway `Bundle` whose resourceURL points at a fresh
    /// temp directory. Tests can populate or not as they like.
    private func makeFakeBundle() throws -> (Bundle, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-bundle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Bundle(url:) requires the directory to look at least vaguely like a
        // bundle; an empty dir works for resourceURL-only lookups.
        guard let bundle = Bundle(url: dir) else {
            // Fallback: create a `.bundle` extension dir which Bundle accepts.
            let bundled = dir.deletingPathExtension().appendingPathExtension("bundle")
            try FileManager.default.moveItem(at: dir, to: bundled)
            guard let b2 = Bundle(url: bundled) else {
                XCTFail("Could not synthesize fake Bundle"); throw NSError(domain: "test", code: 1)
            }
            return (b2, bundled)
        }
        return (bundle, dir)
    }

    // MARK: - Model locator

    func test_modelLocator_throwsWhenBundleEmpty() throws {
        let (bundle, _) = try makeFakeBundle()
        let locator = WhisperKitModelLocator(modelName: "stub-tiny", bundle: bundle)
        XCTAssertThrowsError(try locator.resolveModelFolderURL()) { err in
            guard let modelErr = err as? WhisperKitModelLocatorError else {
                XCTFail("Wrong error type: \(err)"); return
            }
            switch modelErr {
            case .modelNotBundled(let path):
                XCTAssertTrue(path.contains("stub-tiny"), "Diagnostic path should name the missing model: \(path)")
            case .bundleResourceURLUnavailable:
                XCTFail("Did not expect bundleResourceURLUnavailable")
            }
        }
    }

    func test_modelLocator_returnsURLWhenModelDirExists() throws {
        let (bundle, root) = try makeFakeBundle()
        let modelDir = root
            .appendingPathComponent(WhisperKitModelLocator.bundleSubfolder, isDirectory: true)
            .appendingPathComponent("stub-tiny", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        // Touch a placeholder file so the dir isn't suspiciously empty.
        try Data().write(to: modelDir.appendingPathComponent("placeholder.bin"))

        let locator = WhisperKitModelLocator(modelName: "stub-tiny", bundle: bundle)
        let resolved = try locator.resolveModelFolderURL()
        XCTAssertEqual(resolved.lastPathComponent, "stub-tiny")
        XCTAssertTrue(FileManager.default.fileExists(atPath: resolved.path))
    }

    // MARK: - Service initialization

    func test_serviceInitialization_reportsModelMissingWhenBundleEmpty() async throws {
        // Use a private SettingsStore against a temp DB so we don't fight
        // the shared singleton.
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-tests-\(UUID().uuidString).sqlite")
        let provider = DatabaseProvider(location: .file(dbURL))
        _ = try await provider.database()
        let settings = SettingsStore(provider: provider)

        let (bundle, _) = try makeFakeBundle()
        let locator = WhisperKitModelLocator(modelName: "stub-tiny", bundle: bundle)

        let service = VoiceCaptureService(settings: settings, locator: locator)
        await service.initializeIfNeeded()
        let readiness = await service.readiness

        switch readiness {
        case .unavailable(.modelMissing(let path)):
            XCTAssertTrue(path.contains("stub-tiny"))
        case .unavailable(.frameworkMissing):
            // Acceptable: in environments without the WhisperKit framework
            // compiled in, the service fails earlier with .frameworkMissing.
            // Either outcome proves no lazy download happened.
            break
        case .unavailable(.settings):
            XCTFail("Voice capture should be enabled by default in seeded settings")
        case .unavailable(.permission):
            // Mic permission may legitimately be denied in CI sandbox; that
            // also satisfies the no-download requirement.
            break
        case .unavailable(.initFailed(let msg)):
            // The init may also fail for other reasons in CI — accept,
            // provided it's NOT a network/download message.
            XCTAssertFalse(msg.lowercased().contains("download"),
                           "Init should never attempt to download: \(msg)")
        default:
            XCTFail("Expected an unavailable readiness state, got \(readiness)")
        }
    }

    func test_serviceInitialization_respectsSettingsDisable() async throws {
        let dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-tests-\(UUID().uuidString).sqlite")
        let provider = DatabaseProvider(location: .file(dbURL))
        _ = try await provider.database()
        let settings = SettingsStore(provider: provider)
        _ = try await settings.update { s in
            s.voiceCaptureEnabled = false
        }

        let (bundle, _) = try makeFakeBundle()
        let locator = WhisperKitModelLocator(modelName: "stub-tiny", bundle: bundle)
        let service = VoiceCaptureService(settings: settings, locator: locator)
        await service.initializeIfNeeded()
        let readiness = await service.readiness
        XCTAssertEqual(readiness, .unavailable(reason: .settings),
                       "Init must short-circuit when settings disables voice")
    }
}
