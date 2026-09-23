// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Official API model IDs and Standard USD rates, checked 2026-09-22.
/// https://developers.openai.com/api/docs/models
/// https://developers.openai.com/api/docs/pricing
enum OpenAIComputerUseModel: String, CaseIterable, Identifiable {
    case sol = "gpt-6-sol"
    case astra = "gpt-6-astra"
    case luna = "gpt-6-luna"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sol: return "GPT-6 Sol"
        case .astra: return "GPT-6 Astra"
        case .luna: return "GPT-6 Luna"
        }
    }
    var efforts: [OpenAIThinkingEffort] { OpenAIThinkingEffort.allCases.filter { self != .astra || $0 != .none } }
    var inputRate: Double {
        switch self { case .sol: return 2; case .astra: return 10; case .luna: return 0.1 }
    }
    var outputRate: Double {
        switch self { case .sol: return 10; case .astra: return 50; case .luna: return 0.5 }
    }
    var cachedInputRate: Double {
        switch self { case .sol: return 0.2; case .astra: return 1; case .luna: return 0.01 }
    }
    var cacheWriteRate: Double {
        switch self { case .sol: return 2.5; case .astra: return 12.5; case .luna: return 0.125 }
    }
    var priceSummary: String { "US$\(inputRate.formatted()) input · US$\(outputRate.formatted()) output / 1M tokens" }

    /// Output tokens already include reasoning tokens. Never charge them twice.
    /// Cache writes are a separate input category, not an extra copy of ordinary input.
    func estimatedUSD(usage: [String: Any]) -> Double? {
        OpenAIModelCatalog.bundled.entry(self)!.estimatedUSD(usage: usage)
    }
}

/// A value copied into task options; refreshing the catalog cannot reprice a run.
struct OpenAIModelRates: Codable, Equatable {
    let input: Double
    let cachedInput: Double
    let cacheWrite: Double
    let output: Double
    let longContextThreshold: Int
    let longInputMultiplier: Double
    let longOutputMultiplier: Double

    var priceSummary: String { "US$\(input.formatted()) input · US$\(output.formatted()) output / 1M tokens" }
    func estimatedUSD(usage: [String: Any]) -> Double? {
        guard let input = usage["input_tokens"] as? Int, let output = usage["output_tokens"] as? Int,
              input >= 0, output >= 0 else { return nil }
        let details = usage["input_tokens_details"] as? [String: Any] ?? [:]
        let cached = details["cached_tokens"] as? Int ?? 0
        let writes = details["cache_write_tokens"] as? Int ?? 0
        guard cached >= 0, writes >= 0, cached <= input, writes <= input - cached else { return nil }
        let multiplier = input > longContextThreshold ? longInputMultiplier : 1
        let outputMultiplier = input > longContextThreshold ? longOutputMultiplier : 1
        return (Double(input - cached - writes) * self.input * multiplier + Double(cached) * cachedInput * multiplier
            + Double(writes) * cacheWrite * multiplier + Double(output) * self.output * outputMultiplier) / 1_000_000
    }
}

enum OpenAIThinkingEffort: String, CaseIterable, Identifiable, Codable {
    case automatic, none, low, medium, high, xhigh, max
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: return "Model default"
        case .none: return "None"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Maximum"
        }
    }
}

struct OpenAIComputerUseOptions: Equatable {
    var model: OpenAIComputerUseModel = .luna
    var effort: OpenAIThinkingEffort = .automatic
    var catalogEntry: OpenAIModelCatalog.Entry? = nil
    var pricingVerifiedAt: String = OpenAIModelCatalog.bundled.verifiedAt
    var effectiveEffort: OpenAIThinkingEffort { (catalogEntry?.efforts ?? model.efforts).contains(effort) ? effort : .automatic }
    var rates: OpenAIModelRates { (catalogEntry ?? OpenAIModelCatalog.bundled.entry(model)!).rates }
    var label: String { "\(model.title) · \(effectiveEffort.title) thinking" }
    /// Reasoning consumes this allowance too. Explicit higher efforts need room to
    /// return an action/review instead of repeatedly exhausting a small output cap.
    func outputLimit(baseline: Int) -> Int {
        switch effectiveEffort {
        case .none: return baseline
        case .automatic: return max(baseline, 16_384)
        case .low, .medium: return max(baseline, 16_384)
        case .high: return max(baseline, 32_768)
        case .xhigh, .max: return max(baseline, 65_536)
        }
    }
}
