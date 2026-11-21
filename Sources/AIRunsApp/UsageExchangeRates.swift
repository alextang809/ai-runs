import Combine
import Foundation

struct UsageExchangeQuote: Equatable, Sendable {
    static let supportedCurrencies = [
        "AUD", "BRL", "CAD", "CHF", "CNY", "CZK", "DKK", "EUR", "GBP", "HKD",
        "HUF", "IDR", "ILS", "INR", "ISK", "JPY", "KRW", "MXN", "MYR", "NOK",
        "NZD", "PHP", "PLN", "RON", "SEK", "SGD", "THB", "TRY", "USD", "ZAR"
    ]

    let date: String
    private let unitsPerEUR: [String: Decimal]

    func unitsPerUSD(_ currency: String) -> Decimal? {
        unitsPerEUR[currency].flatMap { units in unitsPerEUR["USD"].map { units / $0 } }
    }

    static func parse(_ data: Data) -> Self? {
        guard data.count <= ECBExchangeFeed.maximumBytes,
              let xml = String(data: data, encoding: .utf8), !xml.contains("\0"),
              !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else { return nil }
        let collector = ECBRateCollector()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = collector
        guard parser.parse(), let date = collector.date, collector.rates["USD"] != nil else { return nil }
        return Self(date: date, unitsPerEUR: collector.rates)
    }

    fileprivate static func dateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

@MainActor
final class UsageExchangeRates: ObservableObject {
    typealias Fetch = @Sendable () async throws -> Data

    @Published private(set) var quote: UsageExchangeQuote?
    @Published private(set) var isLoading = false

    private struct CacheEntry: Codable {
        let data: Data
        let fetchedAt: Date
    }

    private static let cacheKey = "usage.exchangeRates.ecb.v1"
    private static let refreshInterval: TimeInterval = 6 * 60 * 60
    private static let retryInterval: TimeInterval = 15 * 60
    private let defaults: UserDefaults
    private let now: () -> Date
    private let fetch: Fetch
    private var nextRefreshAt: Date = .distantPast
    private var refreshTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() },
         fetch: @escaping Fetch = { try await ECBExchangeFeed.fetch() }) {
        self.defaults = defaults
        self.now = now
        self.fetch = fetch
        let currentTime = now()
        if let saved = defaults.data(forKey: Self.cacheKey), saved.count <= 64 * 1_024,
           let entry = try? PropertyListDecoder().decode(CacheEntry.self, from: saved),
           let quote = UsageExchangeQuote.parse(entry.data), Self.isPublishedDate(quote.date, now: currentTime) {
            self.quote = quote
            if entry.fetchedAt <= currentTime {
                nextRefreshAt = entry.fetchedAt.addingTimeInterval(Self.refreshInterval)
            }
        }
    }

    func refreshIfNeeded() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        guard now() >= nextRefreshAt else { return }
        isLoading = true
        // The request supplies every currency. A view changing its selection
        // must not cancel a refresh that the next selection also needs.
        let task = Task { await loadQuote() }
        refreshTask = task
        await task.value
    }

    private func loadQuote() async {
        defer {
            refreshTask = nil
            isLoading = false
        }
        do {
            let data = try await fetch()
            let fetchedAt = now()
            guard let updated = UsageExchangeQuote.parse(data), Self.isPublishedDate(updated.date, now: fetchedAt),
                  quote.map({ updated.date >= $0.date }) ?? true else {
                nextRefreshAt = fetchedAt.addingTimeInterval(Self.retryInterval)
                return
            }
            quote = updated
            nextRefreshAt = fetchedAt.addingTimeInterval(Self.refreshInterval)
            if let saved = try? PropertyListEncoder().encode(CacheEntry(data: data, fetchedAt: fetchedAt)) {
                defaults.set(saved, forKey: Self.cacheKey)
            }
        } catch {
            nextRefreshAt = now().addingTimeInterval(Self.retryInterval)
        }
    }

    private static func isPublishedDate(_ date: String, now: Date) -> Bool {
        date <= UsageExchangeQuote.dateFormatter().string(from: now)
    }
}

private final class ECBRateCollector: NSObject, XMLParserDelegate {
    private static let cubeNamespace = "http://www.ecb.int/vocabulary/2002-08-01/eurofxref"
    private var depth = 0
    private var cubeDepth = 0
    private var hasContainer = false
    private(set) var date: String?
    private(set) var rates: [String: Decimal] = ["EUR": 1]

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        depth += 1
        guard depth <= 8 else { parser.abortParsing(); return }
        if depth == 1 {
            if elementName != "Envelope" || namespaceURI != "http://www.gesmes.org/xml/2002-08-01" {
                parser.abortParsing()
            }
            return
        }

        guard elementName == "Cube", namespaceURI == Self.cubeNamespace else {
            if cubeDepth > 0 { parser.abortParsing() }
            return
        }
        guard depth == cubeDepth + 2 else { parser.abortParsing(); return }
        cubeDepth += 1
        switch cubeDepth {
        case 1:
            guard !hasContainer, attributes.isEmpty else { parser.abortParsing(); return }
            hasContainer = true
        case 2:
            guard date == nil, attributes.count == 1, let time = attributes["time"],
                  Self.isDate(time) else { parser.abortParsing(); return }
            date = time
        case 3:
            guard attributes.count == 2, let code = attributes["currency"], let raw = attributes["rate"],
                  code.utf8.count == 3, code.utf8.allSatisfy({ (65...90).contains($0) }),
                  rates[code] == nil, rates.count < 128, let rate = Self.parseRate(raw) else {
                parser.abortParsing()
                return
            }
            rates[code] = rate
        default:
            parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName: String?) {
        if elementName == "Cube", namespaceURI == Self.cubeNamespace { cubeDepth -= 1 }
        depth -= 1
    }

    private static func isDate(_ value: String) -> Bool {
        guard value.utf8.count == 10 else { return false }
        let formatter = UsageExchangeQuote.dateFormatter()
        return formatter.date(from: value).map { formatter.string(from: $0) == value } ?? false
    }

    private static func parseRate(_ value: String) -> Decimal? {
        guard value.utf8.count <= 25,
              value.range(of: #"\A[0-9]{1,12}(\.[0-9]{1,12})?\z"#, options: .regularExpression) != nil,
              let rate = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              rate > 0, rate <= 1_000_000_000 else { return nil }
        return rate
    }
}

private enum ECBExchangeFeed {
    static let maximumBytes = 32 * 1_024
    private static let endpoint = URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!

    static func fetch() async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: endpoint)
        guard let response = response as? HTTPURLResponse, response.url == endpoint, response.statusCode == 200
        else { throw URLError(.badServerResponse) }
        guard response.expectedContentLength <= maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
