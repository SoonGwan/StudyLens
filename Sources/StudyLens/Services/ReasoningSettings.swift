import Foundation

enum ReasoningPreference: String, CaseIterable, Identifiable {
    case low, medium, high, modelDefault
    var id: String { rawValue }
    var title: String {
        switch self {
        case .low: return "빠르게 (low)"
        case .medium: return "균형 (medium)"
        case .high: return "깊게 (high)"
        case .modelDefault: return "모델 기본값"
        }
    }
}

/// Exact aliases verified in official model documentation; unknown aliases and snapshots fail closed.
enum ModelCapabilities {
    static let adjustableReasoning: Set<String> = [
        "gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna",
        "gpt-5.2", "gpt-5.1", "gpt-5"
    ]
    static let imageInput: Set<String> = adjustableReasoning.union([
        "gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o", "gpt-4o-mini"
    ])

    static func preferences(for model: String) -> [ReasoningPreference] {
        adjustableReasoning.contains(model) ? ReasoningPreference.allCases : [.modelDefault]
    }

    static func validatedEffort(_ effort: String?, model: String) -> String? {
        guard let effort, let preference = ReasoningPreference(rawValue: effort),
              preference != .modelDefault, preferences(for: model).contains(preference) else { return nil }
        return preference.rawValue
    }
}

struct ReasoningSettings {
    let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private static let key = "reasoningPreferences.v1"

    func preference(model: String, mode: BillingMode) -> ReasoningPreference {
        let stored = (defaults.dictionary(forKey: Self.key)?[mode.rawValue + ":" + model] as? String)
            .flatMap(ReasoningPreference.init(rawValue:))
        let allowed = ModelCapabilities.preferences(for: model)
        if let stored { return allowed.contains(stored) ? stored : .modelDefault }
        return allowed.contains(.low) ? .low : .modelDefault
    }

    func set(_ preference: ReasoningPreference, model: String, mode: BillingMode) {
        var values = defaults.dictionary(forKey: Self.key) ?? [:]
        values[mode.rawValue + ":" + model] = ModelCapabilities.preferences(for: model).contains(preference)
            ? preference.rawValue : ReasoningPreference.modelDefault.rawValue
        defaults.set(values, forKey: Self.key)
    }
}
