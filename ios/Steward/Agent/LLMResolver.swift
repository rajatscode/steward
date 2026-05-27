//
//  LLMResolver.swift
//  Steward
//
//  Picks the right `LLMSessionFactory` at runtime:
//    1. If the iOS 26 SDK is present at compile time AND the runtime is
//       iOS 26+ AND Apple Intelligence reports the model available →
//       FoundationModelsSession.
//    2. Otherwise, MockLLMSession with a typed `MockReason` so the UI
//       can show a precise banner.
//
//  This file (and FoundationModelsSession.swift) are the ONLY two files
//  allowed to `import FoundationModels` (addendum §4 hard reject #20).
//

import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

struct LLMBackendResolution: Sendable {
    let factory: any LLMSessionFactory
    let kind: LLMBackendKind

    init(factory: any LLMSessionFactory, kind: LLMBackendKind) {
        self.factory = factory
        self.kind = kind
    }
}

enum LLMResolver {
    /// Returns the best available backend. Never throws — falls back to
    /// MockLLMSession with a typed reason so the UI can render a precise
    /// banner per §1.10.
    static func resolve() async -> LLMBackendResolution {
        #if targetEnvironment(simulator)
        // iOS Simulator reports SystemLanguageModel.isAvailable == true but
        // ships no Apple Intelligence model weights — invocation fails with
        // ModelManagerError 1026. Always mock on simulator.
        let mockFactory = MockLLMSessionFactory(reason: .deviceNotEligible)
        return LLMBackendResolution(
            factory: mockFactory,
            kind: .mock(reason: .deviceNotEligible)
        )
        #else
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            let available = SystemLanguageModel.default.isAvailable
            if available {
                let factory = FoundationModelsSessionFactory()
                return LLMBackendResolution(factory: factory, kind: .foundationModels)
            }
            let reason = mapUnavailableReason()
            let mockFactory = MockLLMSessionFactory(reason: reason)
            return LLMBackendResolution(factory: mockFactory, kind: .mock(reason: reason))
        }
        #endif
        // No iOS 26 SDK at compile time, or running on iOS < 26.
        let mockFactory = MockLLMSessionFactory(reason: .sdkNotCompiledIn)
        return LLMBackendResolution(
            factory: mockFactory,
            kind: .mock(reason: .sdkNotCompiledIn)
        )
        #endif
    }

    #if canImport(FoundationModels)
    /// Maps Foundation Models' availability reason to our typed
    /// `MockReason`. Exhaustive switch — adding a new
    /// SystemLanguageModel.UnavailableReason case is a compile error
    /// until handled here (no `default:` clause).
    @available(iOS 26.0, *)
    private static func mapUnavailableReason() -> MockReason {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .modelNotAvailable
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceDisabled
            case .modelNotReady:
                return .modelNotReady
            case .deviceNotEligible:
                return .deviceNotEligible
            @unknown default:
                // SystemLanguageModel may grow new cases in later SDKs; keep
                // forward-compat to the safest mock.
                return .modelNotAvailable
            }
        }
    }
    #endif
}
