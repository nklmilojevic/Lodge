import AppKit
import FoundationModels

struct AskSearchPlan: Sendable {
  enum Kind: String, Sendable { case any, text, image, link }

  var terms: [String] = []
  var application: String?
  var kind: Kind = .any
  var startDate: Date?
  var endDate: Date?
  var domain: String?

  private static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

  static func domain(_ value: String?) throws -> String? {
    guard let value else { return nil }
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !["", "null", "none"].contains(normalized) else { return nil }
    let host = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-.")
    guard host.contains("."), host.unicodeScalars.allSatisfy({ allowed.contains($0) }),
          !host.contains("..") else { throw AskSearchError.invalidPlan }
    return host
  }

  static func hasEvidence(_ evidence: String?, in query: String) -> Bool {
    guard let evidence else { return false }
    let phrase = evidence.trimmingCharacters(in: .whitespacesAndNewlines)
    return !phrase.isEmpty && query.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive]) != nil
  }

  static func dates(for range: String, now: Date = Date(), calendar: Calendar = .current) throws -> (Date?, Date?) {
    let today = calendar.startOfDay(for: now)
    switch range {
    case "any": return (nil, nil)
    case "today": return (today, calendar.date(byAdding: .day, value: 1, to: today))
    case "yesterday": return (calendar.date(byAdding: .day, value: -1, to: today), today)
    case "lastSevenDays":
      return (calendar.date(byAdding: .day, value: -6, to: today), calendar.date(byAdding: .day, value: 1, to: today))
    case "thisWeek", "lastWeek", "thisMonth", "lastMonth":
      let component: Calendar.Component = range.hasSuffix("Week") ? .weekOfYear : .month
      let reference = range.hasPrefix("last") ? calendar.date(byAdding: component, value: -1, to: now) : now
      guard let reference, let interval = calendar.dateInterval(of: component, for: reference) else {
        throw AskSearchError.invalidPlan
      }
      return (interval.start, interval.end)
    default: throw AskSearchError.invalidPlan
    }
  }

  func matches(_ document: AskSearchDocument, ocr: Bool) -> Bool {
    if let application, !application.isEmpty {
      let source = ContentProcessor.normalize(document.application)
      guard source.contains(ContentProcessor.normalize(application)) else { return false }
    }
    if let startDate, document.copiedAt < startDate { return false }
    if let endDate, document.copiedAt >= endDate { return false }
    if kind == .link || domain != nil {
      let text = document.text
      let links = Self.linkDetector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []
      guard links.contains(where: { match in
        guard let url = match.url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) else {
          return false
        }
        guard let domain else { return true }
        return host == domain || host.hasSuffix("." + domain)
      }) else { return false }
    }
    switch kind {
    case .any: break
    case .image: if !document.hasImage { return false }
    case .text: if document.hasImage || document.text.isEmpty { return false }
    case .link: break
    }
    let text = ContentProcessor.normalize(document.title + "\n" + document.text)
    let imageText = ocr ? ContentProcessor.normalize(document.ocr) : ""
    return terms.allSatisfy {
      let term = ContentProcessor.normalize($0)
      return text.contains(term) || imageText.contains(term)
    }
  }

  static func date(_ value: String?, timeZone: TimeZone = .current) throws -> Date? {
    guard let value else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.isLenient = false
    guard let date = formatter.date(from: value), formatter.string(from: date) == value else {
      throw AskSearchError.invalidPlan
    }
    return date
  }
}

struct AskSearchDocument: Sendable {
  let id: UUID
  var title = ""
  var text = ""
  var ocr = ""
  var application = ""
  var copiedAt = Date()
  var hasImage = false
}

enum AskSearchError: Error { case unavailable, invalidPlan, queryTooLong }

enum AskSearch {
  static var availabilityMessage: String? {
    guard #available(macOS 26, *) else {
      return "Ask requires macOS 26 or later. Exact search is available."
    }
    switch SystemLanguageModel.default.availability {
    case .available: return nil
    case .unavailable(.deviceNotEligible):
      return "Ask requires a Mac that supports Apple Intelligence. Exact search is available."
    case .unavailable(.appleIntelligenceNotEnabled):
      return "Turn on Apple Intelligence to use Ask. Exact search is available."
    case .unavailable(.modelNotReady):
      return "The Apple Intelligence model is not ready. Exact search is available."
    default:
      return "Apple Intelligence is unavailable. Exact search is available."
    }
  }

  @MainActor
  static func plan(for query: String) async throws -> AskSearchPlan {
    guard #available(macOS 26, *), availabilityMessage == nil else { throw AskSearchError.unavailable }
    guard query.count <= 1_000 else { throw AskSearchError.queryTooLong }
    let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: """
      Extract filters for a clipboard search.
      Website names refer to URL hostnames: GitHub means github.com, YouTube means youtube.com.
      Source apps are where content was copied from, such as Safari, Brave, or Slack.
      Only set application when a source app is requested. A website is not a source app.
      An app after 'from' is not a website filter. Do not invent a domain for the source app.
      datePhrase must quote a date phrase from the request, such as yesterday. Otherwise null.
      terms contains essential content words only. Exclude website, app, date, and type words.
      For github links: domain github.com, application null, datePhrase null, kind link, terms [].
      For YouTube links: domain youtube.com, application null, datePhrase null, kind link, terms [].
      For URLs copied from Chrome today: domain null, application Chrome, datePhrase today, kind link, terms [].
      For links from Safari yesterday: domain null, application Safari, datePhrase yesterday, kind link, terms [].
      For GitHub links from Brave yesterday: domain github.com, application Brave,
      datePhrase yesterday, kind link, terms [].
      For images with invoice numbers: domain null, application null, datePhrase null, kind image, terms [invoice].
      """)
    let response = try await session.respond(to: query, generating: GeneratedSearchPlan.self,
                                            options: GenerationOptions(temperature: 0, maximumResponseTokens: 400))
    try Task.checkCancellation()
    let generated = response.content
    let domain = generated.kind == .link ? try AskSearchPlan.domain(generated.domain) : nil
    let start: Date?
    let end: Date?
    if let phrase = generated.datePhrase, AskSearchPlan.hasEvidence(phrase, in: query) {
      (start, end) = try await dates(for: phrase)
    } else {
      start = nil
      end = nil
    }
    if let start, let end, start >= end { throw AskSearchError.invalidPlan }
    let terms = generated.terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    guard terms.count <= 12, terms.allSatisfy({ $0.count <= 200 }) else { throw AskSearchError.invalidPlan }
    let application = AskSearchPlan.hasEvidence(generated.application, in: query) ? generated.application : nil
    return AskSearchPlan(terms: terms, application: application,
                         kind: AskSearchPlan.Kind(rawValue: generated.kind.rawValue) ?? .any,
                         startDate: start, endDate: end, domain: domain)
  }

  @available(macOS 26, *)
  private static func dates(for phrase: String) async throws -> (Date?, Date?) {
    let relativeRanges = ["today": "today", "yesterday": "yesterday", "this week": "thisWeek",
                          "last week": "lastWeek", "this month": "thisMonth", "last month": "lastMonth",
                          "last seven days": "lastSevenDays", "last 7 days": "lastSevenDays",
                          "past week": "lastSevenDays"]
    if let range = relativeRanges[phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)] {
      return try AskSearchPlan.dates(for: range)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.dateFormat = "yyyy-MM-dd EEEE"
    let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: """
      Convert a date phrase into a local calendar date range.
      Today is \(formatter.string(from: Date())) in \(TimeZone.current.identifier).
      startDate is inclusive. endDate is exclusive. Use yyyy-MM-dd.
      For a single day, endDate is the next day. Use null for an open boundary only.
      """)
    let response = try await session.respond(to: phrase, generating: GeneratedDateRange.self,
                                            options: GenerationOptions(temperature: 0, maximumResponseTokens: 100))
    try Task.checkCancellation()
    let start = try AskSearchPlan.date(response.content.startDate)
    let end = try AskSearchPlan.date(response.content.endDate)
    guard start != nil || end != nil else { throw AskSearchError.invalidPlan }
    return (start, end)
  }

  @MainActor
  static func search(_ plan: AskSearchPlan, within items: [HistoryItemDecorator], ocr: Bool) async -> [Search.SearchResult] {
    let documents = items.map {
      AskSearchDocument(id: $0.id, title: $0.title, text: $0.searchableText, ocr: $0.ocrText,
                        application: [$0.application, $0.item.application].compactMap { $0 }.joined(separator: " "),
                        copiedAt: $0.item.lastCopiedAt, hasImage: $0.hasImage)
    }
    let worker = Task.detached(priority: .userInitiated) {
      documents.compactMap { document -> UUID? in
        guard !Task.isCancelled, plan.matches(document, ocr: ocr) else { return nil }
        return document.id
      }
    }
    let ids = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    let matches = Set(ids)
    return items.filter { matches.contains($0.id) }.map { Search.SearchResult(object: $0) }
  }
}

@available(macOS 26, *)
@Generable
private struct GeneratedSearchPlan {
  @Generable
  enum Kind: String { case any, text, image, link }

  @Guide(description: "Requested content type. Requests for links or URLs use link. Otherwise use the requested type or any.")
  var kind: Kind
  @Guide(description: "Destination website hostname. GitHub links means github.com. A source browser is not a website.")
  var domain: String?
  @Guide(description: "App explicitly requested as the copy source, such as from Safari. For YouTube links alone, null.")
  var application: String?
  @Guide(description: "Exact date words from the user's request, such as yesterday. Null if there are no date words.")
  var datePhrase: String?
  @Guide(description: "Content words only. Exclude website, app, date, and type words. For github links, use [].")
  var terms: [String]
}

@available(macOS 26, *)
@Generable
private struct GeneratedDateRange {
  @Guide(description: "Inclusive local start date as yyyy-MM-dd, or null for no lower bound.")
  var startDate: String?
  @Guide(description: "Exclusive local end date as yyyy-MM-dd, or null for no upper bound.")
  var endDate: String?
}
