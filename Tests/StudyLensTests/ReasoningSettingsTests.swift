import XCTest
@testable import StudyLens

final class ReasoningSettingsTests: XCTestCase {
    func testNewPreferencesDefaultLowOnlyForVerifiedModels() {
        XCTAssertEqual(ModelCapabilities.preferences(for: "gpt-6.1-sol"), [.low, .medium, .high, .modelDefault])
        XCTAssertEqual(ModelCapabilities.preferences(for: "gpt-4.1-mini"), [.modelDefault])
        XCTAssertEqual(ModelCapabilities.preferences(for: "gpt-6.1-sol-unknown"), [.modelDefault])
        XCTAssertNil(ModelCapabilities.validatedEffort("none", model: "gpt-6.1-sol"))
        XCTAssertNil(ModelCapabilities.validatedEffort("minimal", model: "gpt-6.1-sol"))
    }

    func testSavedPreferencesRestorePerModelAndBillingModeAndRevalidate() throws {
        let suite = "StudyLens.Reasoning.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ReasoningSettings(defaults: defaults)
        XCTAssertEqual(settings.preference(model: "gpt-6.1-sol", mode: .chatGPT), .low)
        XCTAssertEqual(settings.preference(model: "unknown", mode: .apiKey), .modelDefault)
        settings.set(.high, model: "gpt-6.1-sol", mode: .chatGPT)
        settings.set(.medium, model: "gpt-6.1-sol", mode: .apiKey)
        settings.set(.modelDefault, model: "gpt-5.2", mode: .apiKey)
        settings.set(.high, model: "unknown", mode: .apiKey)
        let restored = ReasoningSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        XCTAssertEqual(restored.preference(model: "gpt-6.1-sol", mode: .chatGPT), .high)
        XCTAssertEqual(restored.preference(model: "gpt-6.1-sol", mode: .apiKey), .medium)
        XCTAssertEqual(restored.preference(model: "gpt-5.2", mode: .apiKey), .modelDefault)
        XCTAssertEqual(restored.preference(model: "unknown", mode: .apiKey), .modelDefault)
        defaults.set(["apiKey:unknown": "high"], forKey: "reasoningPreferences.v1")
        XCTAssertEqual(restored.preference(model: "unknown", mode: .apiKey), .modelDefault)
    }
}
