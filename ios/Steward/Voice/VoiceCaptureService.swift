//
//  VoiceCaptureService.swift
//  Steward — Track E placeholder for Track F's WhisperKit-backed implementation.
//
//  The UI (Track E) needs a stable symbol it can compile against and feature-
//  detect at runtime: when `VoiceCaptureService.shared.availability == .ready`
//  the mic button is live; otherwise it renders disabled with the tooltip copy
//  from `design/ui-specs.md` §1.6.
//
//  Track F will replace `MissingVoiceCaptureService` with a real WhisperKit-
//  backed implementation by setting `VoiceCaptureService.shared = WhisperKit…`
//  at app bootstrap before any view appears. Until then this placeholder is
//  the lone conformance and reports `.notLoaded`.
//

import Foundation

/// Why the mic button is unavailable. Each case maps to a piece of UI copy from
/// `design/ui-specs.md` §1.6.
public enum VoiceAvailability: Sendable, Equatable {
    case ready
    case notLoaded          // Track F not wired yet, or WhisperKit failed to load.
    case permissionDenied   // User declined microphone access.
    case disabledInSettings // `settings.voice_capture_enabled = false`.
}

/// Minimal voice-capture surface the UI binds against. Track F adds a real
/// hold-to-talk implementation later; the UI does not depend on its details,
/// only on `availability` and a single async `transcribe()` entry point.
public protocol VoiceCaptureService: AnyObject, Sendable {
    var availability: VoiceAvailability { get async }

    /// Begin recording on press-down. The implementation is expected to be
    /// idempotent if `beginRecording` is called twice without an intervening
    /// stop (Track F decides — UI just forwards the press-down event).
    func beginRecording() async

    /// Stop and transcribe. Returns nil if cancelled or if no audio was
    /// captured. Throws on hard failure (mic in use, transcription error).
    func endRecordingAndTranscribe() async throws -> String?

    /// User dragged off the button; throw away the buffer.
    func cancelRecording() async
}

/// Process-wide handle. Default is `MissingVoiceCaptureService`; Track F swaps
/// in its real implementation during bootstrap. Reads from main-thread UI code
/// go through `VoiceCaptureRegistry.current` which is `@MainActor`.
@MainActor
public enum VoiceCaptureRegistry {
    public static var current: any VoiceCaptureService = MissingVoiceCaptureService()
}

/// Reports `.notLoaded` and refuses to record. The UI renders the disabled
/// state + tooltip "Voice isn't ready right now. You can still type."
public final class MissingVoiceCaptureService: VoiceCaptureService {
    public init() {}
    public var availability: VoiceAvailability { get async { .notLoaded } }
    public func beginRecording() async {}
    public func endRecordingAndTranscribe() async throws -> String? { nil }
    public func cancelRecording() async {}
}
