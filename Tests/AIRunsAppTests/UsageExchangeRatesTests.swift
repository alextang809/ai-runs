import Foundation
import XCTest
@testable import AIRunsApp

final class UsageExchangeRatesTests: XCTestCase {
    func testConvertsEURBaseRatesToUSD() throws {
        let quote = try XCTUnwrap(UsageExchangeQuote.parse(feed()))
        XCTAssertEqual(quote.date, "2026-11-20")
        XCTAssertEqual(quote.unitsPerUSD("USD"), 1)
        XCTAssertEqual(quote.unitsPerUSD("EUR"), Decimal(4) / 5)
        XCTAssertEqual(quote.unitsPerUSD("SGD"), Decimal(6) / 5)
        XCTAssertEqual(quote.unitsPerUSD("JPY"), 120)
        XCTAssertNil(quote.unitsPerUSD("CAD"))
    }

    func testRejectsMalformedSuspiciousAndIncompleteFeed() {
        XCTAssertNil(UsageExchangeQuote.parse(Data("<html>not a feed</html>".utf8)))
        XCTAssertNil(UsageExchangeQuote.parse(feed(date: "2026-02-30")))
        XCTAssertNil(UsageExchangeQuote.parse(feed(usd: "0")))
        XCTAssertNil(UsageExchangeQuote.parse(feed(usd: "-1.25")))
        XCTAssertNil(UsageExchangeQuote.parse(feed(usd: "1.25bogus")))
        XCTAssertNil(UsageExchangeQuote.parse(feed(usd: "1e999")))
        XCTAssertNil(UsageExchangeQuote.parse(feed(extra: "<Cube currency='USD' rate='2'/>")))
        XCTAssertNil(UsageExchangeQuote.parse(feed(extra: "<Cube currency='EUR' rate='9'/>")))
        XCTAssertNil(UsageExchangeQuote.parse(feed(extra: "<Cube currency='xx' rate='9'/>")))
        XCTAssertNil(UsageExchangeQuote.parse(feed(usd: nil)))
        XCTAssertNil(UsageExchangeQuote.parse(feed(prefix: "<!DOCTYPE gesmes:Envelope [<!ENTITY rates SYSTEM 'file:///tmp/rates'>]>")))
        XCTAssertNil(UsageExchangeQuote.parse(Data(repeating: 65, count: 32_769)))
    }

    @MainActor
    func testCachesValidQuoteForOfflineUseAndDoesNotRefetchWhileFresh() async throws {
        let key = "usage-exchange-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let today = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-21T12:00:00Z"))
        let successfulFetch = ExchangeFetch(result: .success(feed()))
        let first = UsageExchangeRates(defaults: defaults, now: { today }, fetch: { try await successfulFetch.get() })
        await first.refreshIfNeeded()
        await first.refreshIfNeeded()
        XCTAssertEqual(first.quote?.unitsPerUSD("SGD"), Decimal(6) / 5)
        let fetches = await successfulFetch.count
        XCTAssertEqual(fetches, 1)

        let offline = ExchangeFetch(result: .failure(URLError(.notConnectedToInternet)))
        let reopened = UsageExchangeRates(defaults: defaults, now: { today.addingTimeInterval(86_400) },
                                          fetch: { try await offline.get() })
        XCTAssertEqual(reopened.quote?.date, "2026-11-20")
        await reopened.refreshIfNeeded()
        let offlineFetches = await offline.count
        XCTAssertEqual(offlineFetches, 1)
        XCTAssertEqual(reopened.quote?.unitsPerUSD("SGD"), Decimal(6) / 5)
        XCTAssertFalse(reopened.isLoading)
    }

    @MainActor
    func testUnusableResponseCannotReplaceSavedReferenceDate() async throws {
        let key = "usage-exchange-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let today = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-21T12:00:00Z"))
        let valid = feed()
        let first = UsageExchangeRates(defaults: defaults, now: { today }, fetch: { valid })
        await first.refreshIfNeeded()

        for invalid in [feed(date: "2026-11-19", usd: "2"), feed(date: "2099-11-23"), feed(usd: "0")] {
            let later = UsageExchangeRates(defaults: defaults, now: { today.addingTimeInterval(86_400) },
                                           fetch: { invalid })
            await later.refreshIfNeeded()
            XCTAssertEqual(later.quote?.date, "2026-11-20")
            XCTAssertEqual(later.quote?.unitsPerUSD("SGD"), Decimal(6) / 5)
        }
    }

    @MainActor
    func testLoadSurvivesCancellationByAnIndividualCaller() async throws {
        let key = "usage-exchange-tests-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: key))
        defer { defaults.removePersistentDomain(forName: key) }
        let today = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-21T12:00:00Z"))
        let started = expectation(description: "fetch started")
        let fetch = DeferredExchangeFetch(started: started)
        let rates = UsageExchangeRates(defaults: defaults, now: { today }, fetch: { await fetch.get() })
        let first = Task { await rates.refreshIfNeeded() }
        await fulfillment(of: [started], timeout: 1)
        first.cancel()

        let joined = expectation(description: "second caller")
        let second = Task {
            joined.fulfill()
            await rates.refreshIfNeeded()
        }
        await fulfillment(of: [joined], timeout: 1)
        await fetch.finish(with: feed())
        await first.value
        await second.value
        XCTAssertEqual(rates.quote?.unitsPerUSD("SGD"), Decimal(6) / 5)
        let fetches = await fetch.count
        XCTAssertEqual(fetches, 1)
    }

    private func feed(date: String = "2026-11-20", usd: String? = "1.25", extra: String = "", prefix: String = "") -> Data {
        let dollars = usd.map { "<Cube currency='USD' rate='\($0)'/>" } ?? ""
        return Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        \(prefix)
        <gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01"
            xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">
          <gesmes:subject>Reference rates</gesmes:subject>
          <gesmes:Sender><gesmes:name>European Central Bank</gesmes:name></gesmes:Sender>
          <Cube><Cube time="\(date)">
            \(dollars)<Cube currency="SGD" rate="1.50"/><Cube currency="JPY" rate="150"/>
            \(extra)
          </Cube></Cube>
        </gesmes:Envelope>
        """.utf8)
    }
}

private actor ExchangeFetch {
    let result: Result<Data, URLError>
    private(set) var count = 0

    init(result: Result<Data, URLError>) { self.result = result }

    func get() throws -> Data {
        count += 1
        return try result.get()
    }
}

private actor DeferredExchangeFetch {
    let started: XCTestExpectation
    private(set) var count = 0
    private var pending: [CheckedContinuation<Data, Never>] = []
    private var result: Data?

    init(started: XCTestExpectation) { self.started = started }

    func get() async -> Data {
        count += 1
        if let result { return result }
        return await withCheckedContinuation {
            pending.append($0)
            if count == 1 { started.fulfill() }
        }
    }

    func finish(with data: Data) {
        result = data
        for continuation in pending { continuation.resume(returning: data) }
        pending.removeAll()
    }
}
