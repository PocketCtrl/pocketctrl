// SPDX-License-Identifier: MPL-2.0
import Combine
import Foundation

/// Reviewed data only: the catalog cannot supply endpoints, prompts, tools or code.
struct OpenAIModelCatalog: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let id: String
        let enabled: Bool
        let efforts: [OpenAIThinkingEffort]
        let rates: OpenAIModelRates
        func estimatedUSD(usage: [String: Any]) -> Double? { rates.estimatedUSD(usage: usage) }
    }
    let schemaVersion: Int
    let revision: Int
    let verifiedAt: String
    let models: [Entry]
    func entry(_ model: OpenAIComputerUseModel) -> Entry? { models.first { $0.id == model.rawValue } }

    static let bundled = OpenAIModelCatalog(schemaVersion: 1, revision: 2, verifiedAt: "2026-09-22",
        models: OpenAIComputerUseModel.allCases.map {
            Entry(id: $0.rawValue, enabled: true, efforts: $0.efforts,
                  rates: .init(input: $0.inputRate, cachedInput: $0.cachedInputRate,
                               cacheWrite: $0.cacheWriteRate, output: $0.outputRate,
                               longContextThreshold: 272_000, longInputMultiplier: 2, longOutputMultiplier: 1.5))
        })

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 256_000 else { throw CatalogFailure.invalid }
        let catalog = try JSONDecoder().decode(Self.self, from: data)
        let date = ISO8601DateFormatter().date(from: catalog.verifiedAt + "T00:00:00Z")
        guard catalog.schemaVersion == 1, catalog.revision >= 1,
              catalog.verifiedAt.count == 10, let date, date < Date().addingTimeInterval(86400),
              !catalog.models.isEmpty, catalog.models.count <= 100,
              Set(catalog.models.map(\.id)).count == catalog.models.count else { throw CatalogFailure.invalid }
        for entry in catalog.models {
            let rates = entry.rates
            guard !entry.id.isEmpty, entry.id.count <= 100,
                  !entry.efforts.isEmpty, entry.efforts.contains(.automatic),
                  Set(entry.efforts).count == entry.efforts.count,
                  [rates.input, rates.cachedInput, rates.cacheWrite, rates.output].allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 10_000 }),
                  (1...10_000_000).contains(rates.longContextThreshold),
                  [rates.longInputMultiplier, rates.longOutputMultiplier].allSatisfy({ $0.isFinite && $0 >= 1 && $0 <= 100 }) else { throw CatalogFailure.invalid }
            if let known = OpenAIComputerUseModel(rawValue: entry.id), !entry.efforts.allSatisfy({ known.efforts.contains($0) }) {
                throw CatalogFailure.invalid
            }
        }
        return catalog
    }
}

private enum CatalogFailure: Error { case invalid, http }

/// Never follow a redirect with an API key, or move catalog trust to another origin.
final class CatalogNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class OpenAIModelCatalogStore: ObservableObject {
    static let catalogURL = URL(string: "https://www.pocketctrl.com/ai/openai-models.json")!
    static let modelsURL = URL(string: "https://api.openai.com/v1/models")!
    static let cacheKey = "PocketCtrl.computerUse.openAICatalog.v1"
    @Published private(set) var catalog: OpenAIModelCatalog
    @Published private(set) var source: String
    @Published private(set) var availableIDs: Set<String>?
    @Published private(set) var isRefreshing = false
    @Published private(set) var catalogMessage = ""
    @Published private(set) var availabilityMessage = "Model access has not been checked."
    private let defaults: UserDefaults
    private let session: URLSession
    private var generation = UUID()
    private var lastCatalogAttempt = Date.distantPast
    private var lastAvailabilityAttempt = Date.distantPast
    private var availabilityCheckedAt = Date.distantPast
    private let ttl: TimeInterval = 86400

    init(defaults: UserDefaults = .standard, session: URLSession? = nil) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.cacheKey), let cached = try? OpenAIModelCatalog.decode(data),
           cached.revision >= OpenAIModelCatalog.bundled.revision {
            catalog = cached; source = "Cached catalog"
        } else { catalog = .bundled; source = "Bundled catalog" }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 20; config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = session ?? URLSession(configuration: config, delegate: CatalogNoRedirectDelegate(), delegateQueue: nil)
    }
    func invalidateKey() {
        generation = UUID(); availableIDs = nil; lastAvailabilityAttempt = .distantPast
        availabilityCheckedAt = .distantPast
        availabilityMessage = "Model access has not been checked for this key."
    }
    func permits(_ model: OpenAIComputerUseModel) -> Bool {
        guard catalog.entry(model)?.enabled == true else { return false }
        // An old or unsuccessful access check is unknown, never a permanent denial.
        guard Date().timeIntervalSince(availabilityCheckedAt) < ttl, let availableIDs else { return true }
        return availableIDs.contains(model.rawValue)
    }
    var selectableModels: [OpenAIComputerUseModel] { OpenAIComputerUseModel.allCases.filter { permits($0) } }

    func refresh(key: String?, force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true; defer { isRefreshing = false }
        let token = generation
        if force || Date().timeIntervalSince(lastCatalogAttempt) >= ttl {
            lastCatalogAttempt = Date()
            do {
                let data = try await fetch(Self.catalogURL, key: nil, limit: 256_000)
                let update = try OpenAIModelCatalog.decode(data)
                guard update.revision >= catalog.revision, update.revision != catalog.revision || update == catalog else { throw CatalogFailure.invalid }
                catalog = update; source = "Website catalog"; catalogMessage = ""
                defaults.set(data, forKey: Self.cacheKey)
            } catch { catalogMessage = "Catalog update unavailable; using \(source.lowercased())." }
        }
        guard token == generation else { return }
        guard let key, !key.isEmpty else {
            availableIDs = nil; availabilityMessage = "Save an OpenAI key to check model access."; return
        }
        if force || Date().timeIntervalSince(lastAvailabilityAttempt) >= ttl {
            lastAvailabilityAttempt = Date()
            do {
                let data = try await fetch(Self.modelsURL, key: key, limit: 2_000_000)
                struct ModelList: Decodable {
                    struct Model: Decodable { let id: String; let shutdown_date: String? }
                    let object: String
                    let data: [Model]
                }
                let list = try JSONDecoder().decode(ModelList.self, from: data)
                guard list.object == "list", list.data.count <= 10_000 else { throw CatalogFailure.invalid }
                let today = String(ISO8601DateFormatter().string(from: Date()).prefix(10))
                let ids = Set(list.data.filter { $0.shutdown_date == nil || $0.shutdown_date! > today }.map(\.id))
                guard token == generation else { return }
                availableIDs = ids; availabilityCheckedAt = Date()
                availabilityMessage = "Access checked. \(selectableModels.count) compatible models available."
            } catch {
                guard token == generation else { return }
                availableIDs = nil
                availabilityMessage = "Couldn’t list models. Check the key’s Models read permission, or use Test Connection."
            }
        }
    }

    private func fetch(_ url: URL, key: String?, limit: Int) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        // Stream with a hard bound; an oversized response cannot fill memory before validation.
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.url == url, response.expectedContentLength <= Int64(limit) else { throw CatalogFailure.http }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw CatalogFailure.invalid }
            data.append(byte)
        }
        return data
    }
}
