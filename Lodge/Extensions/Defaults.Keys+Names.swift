import AppKit
import Defaults

struct StorageType {
  static let files = StorageType(types: [.fileURL])
  static let images = StorageType(types: [.png, .tiff])
  static let text = StorageType(types: [.html, .rtf, .string])
  static let all = StorageType(types: files.types + images.types + text.types)

  var types: [NSPasteboard.PasteboardType]
}



extension Defaults.Keys {
  static let historyDataLimitMB = Key<Int>("historyDataLimitMB", default: 512, suite: AppPreferences.suite)
  static let compactView = Key<Bool>("compactView", default: false, suite: AppPreferences.suite)
  static let listWidth = Key<Double>("listWidth", default: 300, suite: AppPreferences.suite)
  static let compactWindowSize = Key<NSSize>("compactWindowSize", default: NSSize(width: 360, height: 540), suite: AppPreferences.suite)
  static let clearOnQuit = Key<Bool>("clearOnQuit", default: false, suite: AppPreferences.suite)
  static let clearSystemClipboard = Key<Bool>("clearSystemClipboard", default: false, suite: AppPreferences.suite)
  static let clipboardCheckInterval = Key<Double>("clipboardCheckInterval", default: 0.5, suite: AppPreferences.suite)
  static let enabledPasteboardTypes = Key<Set<NSPasteboard.PasteboardType>>(
    "enabledPasteboardTypes", default: Set(StorageType.all.types), suite: AppPreferences.suite
  )
  static let highlightMatch = Key<HighlightMatch>("highlightMatch", default: .bold, suite: AppPreferences.suite)
  static let ignoreAllAppsExceptListed = Key<Bool>("ignoreAllAppsExceptListed", default: false, suite: AppPreferences.suite)
  static let ignoreEvents = Key<Bool>("ignoreEvents", default: false, suite: AppPreferences.suite)
  static let ignoreOnlyNextEvent = Key<Bool>("ignoreOnlyNextEvent", default: false, suite: AppPreferences.suite)
  static let ignoreRegexp = Key<[String]>("ignoreRegexp", default: [], suite: AppPreferences.suite)
  static let ignoredApps = Key<[String]>("ignoredApps", default: [], suite: AppPreferences.suite)
  static let ignoredPasteboardTypes = Key<Set<String>>(
    "ignoredPasteboardTypes",
    default: Set([
      "Pasteboard generator type",
      "com.agilebits.onepassword",
      "com.typeit4me.clipping",
      "de.petermaurer.TransientPasteboardType",
      "net.antelle.keeweb"
    ]), suite: AppPreferences.suite
  )
  static let imageMaxHeight = Key<Int>("imageMaxHeight", default: 40, suite: AppPreferences.suite)
  static let lastReviewRequestedAt = Key<Date>("lastReviewRequestedAt", default: Date.now, suite: AppPreferences.suite)
  static let menuIcon = Key<MenuIcon>("menuIcon", default: .lodge, suite: AppPreferences.suite)
  static let migrations = Key<[String: Bool]>("migrations", default: [:], suite: AppPreferences.suite)
  static let numberOfUsages = Key<Int>("numberOfUsages", default: 0, suite: AppPreferences.suite)
  static let pasteByDefault = Key<Bool>("pasteByDefault", default: false, suite: AppPreferences.suite)
  static let pinTo = Key<PinsPosition>("pinTo", default: .top, suite: AppPreferences.suite)
  static let popupFontSize = Key<Int>("popupFontSize", default: 13, suite: AppPreferences.suite)
  static let popupPosition = Key<PopupPosition>("popupPosition", default: .center, suite: AppPreferences.suite)

  static let popupScreen = Key<Int>("popupScreen", default: 0, suite: AppPreferences.suite)
  static let ocrInImages = Key<Bool>("ocrInImages", default: true, suite: AppPreferences.suite)
  static let previewDelay = Key<Int>("previewDelay", default: 1500, suite: AppPreferences.suite)
  static let removeFormattingByDefault = Key<Bool>("removeFormattingByDefault", default: false, suite: AppPreferences.suite)
  static let searchMode = Key<Search.Mode>("searchMode", default: .exact, suite: AppPreferences.suite)
  static let showFooter = Key<Bool>("showFooter", default: true, suite: AppPreferences.suite)
  static let showInStatusBar = Key<Bool>("showInStatusBar", default: true, suite: AppPreferences.suite)
  static let showRecentCopyInMenuBar = Key<Bool>("showRecentCopyInMenuBar", default: false, suite: AppPreferences.suite)
  static let showSearch = Key<Bool>("showSearch", default: true, suite: AppPreferences.suite)
  static let searchVisibility = Key<SearchVisibility>("searchVisibility", default: .always, suite: AppPreferences.suite)
  static let showSpecialSymbols = Key<Bool>("showSpecialSymbols", default: true, suite: AppPreferences.suite)
  static let showTitle = Key<Bool>("showTitle", default: false, suite: AppPreferences.suite)
  static let size = Key<Int>("historySize", default: 200, suite: AppPreferences.suite)
  static let sortBy = Key<Sorter.By>("sortBy", default: .lastCopiedAt, suite: AppPreferences.suite)
  static let suppressClearAlert = Key<Bool>("suppressClearAlert", default: false, suite: AppPreferences.suite)
  static let windowSize = Key<NSSize>("windowSize", default: NSSize(width: 540, height: 540), suite: AppPreferences.suite)
  static let windowPosition = Key<NSPoint>("windowPosition", default: NSPoint(x: 0.5, y: 0.8), suite: AppPreferences.suite)
  static let showApplicationIcons = Key<Bool>("showApplicationIcons", default: true, suite: AppPreferences.suite)
}

// Unit tests use a separate preferences domain and never change app preferences.
enum AppPreferences {
  static let isTesting = CommandLine.arguments.contains("enable-testing")
  static let suite: UserDefaults = {
    guard isTesting else { return .standard }
    let name = "com.nklmilojevic.Lodge.tests.\(ProcessInfo.processInfo.processIdentifier)"
    let suite = UserDefaults(suiteName: name)!
    suite.removePersistentDomain(forName: name)
    return suite
  }()
}
