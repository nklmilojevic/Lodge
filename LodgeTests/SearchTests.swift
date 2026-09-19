import XCTest
import Defaults
@testable import Lodge

class SearchTests: XCTestCase {
  let savedSearchMode = Defaults[.searchMode]
  var items: [HistoryItemDecorator]!

  func testAskFiltersAppTypeDateAndTextTogether() throws {
    let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
    let start = try XCTUnwrap(AskSearchPlan.date("2026-09-17", timeZone: zone))
    let end = try XCTUnwrap(AskSearchPlan.date("2026-09-18", timeZone: zone))
    let plan = AskSearchPlan(terms: ["invoice"], application: "Safari", kind: .image,
                             startDate: start, endDate: end)
    var document = AskSearchDocument(id: UUID(), ocr: "Invoice 123", application: "com.apple.Safari",
                                     copiedAt: start, hasImage: true)
    XCTAssertTrue(plan.matches(document, ocr: true))
    XCTAssertFalse(plan.matches(document, ocr: false))
    document.copiedAt = end
    XCTAssertFalse(plan.matches(document, ocr: true))
    document.copiedAt = start.addingTimeInterval(-1)
    XCTAssertFalse(plan.matches(document, ocr: true))
    document.copiedAt = start
    document.application = "Notes"
    XCTAssertFalse(plan.matches(document, ocr: true))
    document.application = "Safari"
    document.hasImage = false
    XCTAssertFalse(plan.matches(document, ocr: true))
  }

  func testAskLinksAndAllTerms() {
    var plan = AskSearchPlan(kind: .link)
    var document = AskSearchDocument(id: UUID(), text: "https://example.com/invoice")
    XCTAssertTrue(plan.matches(document, ocr: false))
    document.text = "See https://example.com/invoice for details"
    XCTAssertTrue(plan.matches(document, ocr: false))
    plan = AskSearchPlan(terms: ["invoice", "paid"], kind: .text)
    XCTAssertFalse(plan.matches(document, ocr: false))
    document.text = "Invoice PAID"
    XCTAssertTrue(plan.matches(document, ocr: false))
  }

  func testAskWebsiteLinksMatchHostsAcrossAppsAndDates() throws {
    let plan = AskSearchPlan(kind: .link, domain: try AskSearchPlan.domain("GitHub.COM"))
    var document = AskSearchDocument(id: UUID(), text: "https://github.com/org/repo/issues/12",
                                     application: "Brave Origin", copiedAt: Date(timeIntervalSince1970: 0))
    XCTAssertTrue(plan.matches(document, ocr: false))
    document.application = "Slack"
    document.text = "See [the docs](https://docs.github.com/en) for details."
    XCTAssertTrue(plan.matches(document, ocr: false))
    document.text = "https://notgithub.com/repo"
    XCTAssertFalse(plan.matches(document, ocr: false))
    document.text = "https://github.com.example.org/repo"
    XCTAssertFalse(plan.matches(document, ocr: false))
    document.text = "https://example.org/github.com"
    XCTAssertFalse(plan.matches(document, ocr: false))
    document.text = "GitHub links"
    XCTAssertFalse(plan.matches(document, ocr: false))
    document.text = "mailto:hello@github.com"
    XCTAssertFalse(plan.matches(document, ocr: false))
    document.text = "https://example.org and https://github.com/org/repo"
    XCTAssertTrue(plan.matches(document, ocr: false))
  }

  func testAskWebsiteFilterCombinesWithOtherFilters() {
    let plan = AskSearchPlan(terms: ["issues"], application: "Brave", kind: .link, domain: "github.com")
    var document = AskSearchDocument(id: UUID(), text: "https://github.com/org/repo/issues/12",
                                     application: "Brave Origin")
    XCTAssertTrue(plan.matches(document, ocr: false))
    document.application = "Safari"
    XCTAssertFalse(plan.matches(document, ocr: false))
    document.application = "Brave Origin"
    document.text = "https://github.com/org/repo/pulls"
    XCTAssertFalse(plan.matches(document, ocr: false))
  }

  func testAskFilterEvidenceMustAppearInRequest() {
    XCTAssertFalse(AskSearchPlan.hasEvidence("today", in: "github links"))
    XCTAssertFalse(AskSearchPlan.hasEvidence("from GitHub", in: "github links"))
    XCTAssertFalse(AskSearchPlan.hasEvidence(nil, in: "github links"))
    XCTAssertFalse(AskSearchPlan.hasEvidence("  ", in: "github links"))
    XCTAssertTrue(AskSearchPlan.hasEvidence("from Brave", in: "GitHub links from Brave yesterday"))
    XCTAssertTrue(AskSearchPlan.hasEvidence("yesterday", in: "GitHub links from Brave yesterday"))
  }

  func testAskRejectsInvalidDomains() {
    XCTAssertThrowsError(try AskSearchPlan.domain("https://github.com"))
    XCTAssertThrowsError(try AskSearchPlan.domain("github.com/path"))
    XCTAssertThrowsError(try AskSearchPlan.domain("github..com"))
    XCTAssertThrowsError(try AskSearchPlan.domain("github com"))
    XCTAssertNil(try AskSearchPlan.domain(nil))
    XCTAssertNil(try AskSearchPlan.domain("null"))
    XCTAssertNil(try AskSearchPlan.domain(" None "))
  }

  func testAskRelativeDatesUseCalendarBoundariesAcrossDaylightSaving() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Belgrade"))
    calendar.firstWeekday = 2
    let now = try XCTUnwrap(AskSearchPlan.date("2026-03-29", timeZone: calendar.timeZone))
    let tomorrow = try XCTUnwrap(AskSearchPlan.date("2026-03-30", timeZone: calendar.timeZone))
    let today = try AskSearchPlan.dates(for: "today", now: now, calendar: calendar)
    XCTAssertEqual(today.0, now)
    XCTAssertEqual(today.1, tomorrow)
    XCTAssertEqual(tomorrow.timeIntervalSince(now), 23 * 60 * 60)
    let yesterday = try AskSearchPlan.dates(for: "yesterday", now: tomorrow, calendar: calendar)
    XCTAssertEqual(yesterday.0, now)
    XCTAssertEqual(yesterday.1, tomorrow)
    let week = try AskSearchPlan.dates(for: "thisWeek", now: now, calendar: calendar)
    XCTAssertEqual(week.0, try AskSearchPlan.date("2026-03-23", timeZone: calendar.timeZone))
    XCTAssertEqual(week.1, tomorrow)
    let previousMonth = try AskSearchPlan.dates(for: "lastMonth", now: now, calendar: calendar)
    XCTAssertEqual(previousMonth.0, try AskSearchPlan.date("2026-02-01", timeZone: calendar.timeZone))
    XCTAssertEqual(previousMonth.1, try AskSearchPlan.date("2026-03-01", timeZone: calendar.timeZone))
    XCTAssertThrowsError(try AskSearchPlan.dates(for: "unknown", now: now, calendar: calendar))
  }

  func testAskRejectsInvalidDates() {
    XCTAssertThrowsError(try AskSearchPlan.date("2026-02-30"))
    XCTAssertThrowsError(try AskSearchPlan.date("yesterday"))
    XCTAssertThrowsError(try AskSearchPlan.date("2026-9-1"))
    XCTAssertNil(try AskSearchPlan.date(nil))
  }

  override func tearDown() {
    super.tearDown()
    Defaults[.searchMode] = savedSearchMode
  }

  @MainActor
  func testSimpleSearch() { // swiftlint:disable:this function_body_length
    Defaults[.searchMode] = Search.Mode.exact
    items = [
      HistoryItemDecorator(historyItemWithTitle("foo bar baz")),
      HistoryItemDecorator(historyItemWithTitle("foo bar zaz")),
      HistoryItemDecorator(historyItemWithTitle("xxx yyy zzz"))
    ]

    XCTAssertEqual(search(""), [
      Search.SearchResult(score: nil, object: items[0], ranges: []),
      Search.SearchResult(score: nil, object: items[1], ranges: []),
      Search.SearchResult(score: nil, object: items[2], ranges: [])
    ])
    XCTAssertEqual(search("z"), [
      Search.SearchResult(
        score: nil,
        object: items[0],
        ranges: [range(from: 10, to: 10, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 8, to: 8, in: items[1])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 8, to: 8, in: items[2])]
      )
    ])
    XCTAssertEqual(search("foo"), [
      Search.SearchResult(
        score: nil,
        object: items[0],
        ranges: [range(from: 0, to: 2, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 0, to: 2, in: items[1])]
      )
    ])
    XCTAssertEqual(search("za"), [
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 8, to: 9, in: items[1])]
      )
    ])
    XCTAssertEqual(search("yyy"), [
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 4, to: 6, in: items[2])]
      )
    ])
    XCTAssertEqual(search("fbb"), [])
    XCTAssertEqual(search("m"), [])
  }

  @MainActor
  func testFuzzySearch() { // swiftlint:disable:this function_body_length
    Defaults[.searchMode] = Search.Mode.fuzzy
    items = [
      HistoryItemDecorator(historyItemWithTitle("foo bar baz")),
      HistoryItemDecorator(historyItemWithTitle("foo bar zaz")),
      HistoryItemDecorator(historyItemWithTitle("xxx yyy zzz"))
    ]

    XCTAssertEqual(search(""), [
      Search.SearchResult(score: nil, object: items[0], ranges: []),
      Search.SearchResult(score: nil, object: items[1], ranges: []),
      Search.SearchResult(score: nil, object: items[2], ranges: [])
    ])
    XCTAssertEqual(search("z"), [
      Search.SearchResult(
        score: 0.08,
        object: items[1],
        ranges: [range(from: 8, to: 8, in: items[1]), range(from: 10, to: 10, in: items[1])]
      ),
      Search.SearchResult(
        score: 0.08,
        object: items[2],
        ranges: [range(from: 8, to: 10, in: items[2])]
      ),
      Search.SearchResult(
        score: 0.1,
        object: items[0],
        ranges: [range(from: 10, to: 10, in: items[0])]
      )
    ])
    XCTAssertEqual(search("foo"), [
      Search.SearchResult(
        score: 0.0,
        object: items[0],
        ranges: [range(from: 0, to: 2, in: items[0])]
      ),
      Search.SearchResult(
        score: 0.0,
        object: items[1],
        ranges: [range(from: 0, to: 2, in: items[1])]
      )
    ])
    XCTAssertEqual(search("za"), [
      Search.SearchResult(
        score: 0.08,
        object: items[1],
        ranges: [range(from: 5, to: 5, in: items[1]), range(from: 8, to: 9, in: items[1])]
      ),
      Search.SearchResult(
        score: 0.54,
        object: items[0],
        ranges: [range(from: 5, to: 5, in: items[0]), range(from: 9, to: 10, in: items[0])]
      ),
      Search.SearchResult(
        score: 0.58,
        object: items[2],
        ranges: [range(from: 8, to: 10, in: items[2])]
      )
    ])
    XCTAssertEqual(search("yyy"), [
      Search.SearchResult(
        score: 0.04,
        object: items[2],
        ranges: [range(from: 4, to: 6, in: items[2])]
      )
    ])
    XCTAssertEqual(search("fbb"), [
      Search.SearchResult(
        score: 0.6666666666666666,
        object: items[0],
        ranges: [
          range(from: 0, to: 0, in: items[0]),
          range(from: 4, to: 4, in: items[0]),
          range(from: 8, to: 8, in: items[0])
        ]
      ),
      Search.SearchResult(
        score: 0.6666666666666666,
        object: items[1],
        ranges: [range(from: 0, to: 0, in: items[1]), range(from: 4, to: 4, in: items[1])])
    ])
    XCTAssertEqual(search("m"), [])
  }

  @MainActor
  func testRegexpSearch() { // swiftlint:disable:this function_body_length
    Defaults[.searchMode] = Search.Mode.regexp
    items = [
      HistoryItemDecorator(historyItemWithTitle("foo bar baz")),
      HistoryItemDecorator(historyItemWithTitle("foo bar zaz")),
      HistoryItemDecorator(historyItemWithTitle("xxx yyy zzz"))
    ]

    XCTAssertEqual(search(""), [
      Search.SearchResult(score: nil, object: items[0], ranges: []),
      Search.SearchResult(score: nil, object: items[1], ranges: []),
      Search.SearchResult(score: nil, object: items[2], ranges: [])
    ])
    XCTAssertEqual(search("z+"), [
      Search.SearchResult(
        score: nil,
        object: items[0],
        ranges: [range(from: 10, to: 10, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 8, to: 8, in: items[1])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 8, to: 10, in: items[2])]
      )
    ])
    XCTAssertEqual(search("z*"), [
      Search.SearchResult(
        score: nil,
        object: items[0],
        ranges: [range(from: 0, to: -1, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 0, to: -1, in: items[1])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 0, to: -1, in: items[2])]
      )
    ])
    XCTAssertEqual(search("^foo"), [
      Search.SearchResult(
        score: nil,
        object: items[0], ranges: [range(from: 0, to: 2, in: items[0])]
      ),
      Search.SearchResult(
        score: nil,
        object: items[1], ranges: [range(from: 0, to: 2, in: items[1])]
      )
    ])
    XCTAssertEqual(search(" za"), [
      Search.SearchResult(
        score: nil,
        object: items[1],
        ranges: [range(from: 7, to: 9, in: items[1])]
      )
    ])
    XCTAssertEqual(search("[y]+"), [
      Search.SearchResult(
        score: nil,
        object: items[2],
        ranges: [range(from: 4, to: 6, in: items[2])]
      )
    ])
    XCTAssertEqual(search("fbb"), [])
    XCTAssertEqual(search("m"), [])
  }

  func testCaseAndCanonicalUnicodeMatchInLongText() {
    let documents = [SearchDocument(id: UUID(), title: "Title", text: String(repeating: "x", count: 6_000) + " CAFE\u{301}", ocr: "")]
    XCTAssertEqual(SearchEngine.search(query: "café", documents: documents, mode: "exact", ocr: false).count, 1)
  }

  func testFuzzySearchIncludesTextAfterTheFirstSection() {
    let documents = [SearchDocument(id: UUID(), title: "Title", text: String(repeating: "x", count: 12_000) + " zebra", ocr: "")]
    XCTAssertEqual(SearchEngine.search(query: "zebra", documents: documents, mode: "fuzzy", ocr: false).count, 1)
  }

  @MainActor
  private func search(_ string: String) -> [Search.SearchResult] {
    return Search().search(string: string, within: items)
  }

  // swiftlint:disable:next identifier_name
  @MainActor
  private func range(from: Int, to: Int, in item: HistoryItemDecorator) -> Range<String.Index> {
    let startIndex = item.title.startIndex
    let lowerBound = item.title.index(startIndex, offsetBy: from)
    let upperBound = item.title.index(startIndex, offsetBy: to + 1)

    return lowerBound..<upperBound
  }

  @MainActor
  private func historyItemWithTitle(_ value: String?) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value?.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.title = item.generateTitle()

    return item
  }
}
