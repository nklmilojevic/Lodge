import XCTest
import Defaults
@testable import Lodge

// swiftlint:disable type_body_length
@MainActor
class ClipboardTests: XCTestCase {
  var clipboard: Clipboard!
  let pasteboard = NSPasteboard.withUniqueName()
  let clock = ManualClipboardScheduler()
  let image = NSImage(named: "NSInfo")!
  let coloredString = NSAttributedString(string: "foo",
                                         attributes: [.foregroundColor: NSColor.red])

  let dynamicType = NSPasteboard.PasteboardType(rawValue: "dyn.ah62d4qmxhk4d425try1g44pdsm11g55gsu1e82xnqzv")
    let customType = NSPasteboard.PasteboardType(rawValue: "com.nklmilojevic.ConfidentialType")
  let fileURLType = NSPasteboard.PasteboardType.fileURL
  let htmlType = NSPasteboard.PasteboardType.html
  let rtfType = NSPasteboard.PasteboardType.rtf
  let stringType = NSPasteboard.PasteboardType.string
  let tiffType = NSPasteboard.PasteboardType.tiff
  let transientType = NSPasteboard.PasteboardType.transient
  let unknownType = NSPasteboard.PasteboardType(rawValue: "com.apple.AnnotationKit.AnnotationItem")

  let savedEnabledTypes = Defaults[.enabledPasteboardTypes]
  let savedClipboardCheckInterval = Defaults[.clipboardCheckInterval]
  let savedIgnoreEvents = Defaults[.ignoreEvents]
  let savedIgnoreAllAppsExceptListed = Defaults[.ignoreAllAppsExceptListed]
  let savedIgnoreRegexp = Defaults[.ignoreRegexp]
  let savedIgnoredApps = Defaults[.ignoredApps]
  let savedIgnoredPasteboardTypes = Defaults[.ignoredPasteboardTypes]

  override func setUp() {
    super.setUp()
    clipboard = Clipboard(pasteboard: pasteboard, scheduler: clock)
    Defaults[.clipboardCheckInterval] = 0.1
    Defaults[.enabledPasteboardTypes] = Set(StorageType.all.types)
    Defaults[.ignoreAllAppsExceptListed] = false
    Defaults[.ignoreEvents] = false
    Defaults[.ignoreRegexp] = []
    Defaults[.ignoredApps] = []
    Defaults[.ignoredPasteboardTypes] = []
    clipboard.sourceAppBundleIdentifierOverride = "com.apple.dt.Xcode"
    clipboard.clearHooks()
  }

  override func tearDown() {
    clipboard.stop()
    super.tearDown()
    Defaults[.enabledPasteboardTypes] = savedEnabledTypes
    Defaults[.clipboardCheckInterval] = savedClipboardCheckInterval
    Defaults[.ignoreEvents] = savedIgnoreEvents
    Defaults[.ignoreOnlyNextEvent] = false
    Defaults[.ignoreAllAppsExceptListed] = savedIgnoreAllAppsExceptListed
    Defaults[.ignoreRegexp] = savedIgnoreRegexp
    Defaults[.ignoredApps] = savedIgnoredApps
    Defaults[.ignoredPasteboardTypes] = savedIgnoredPasteboardTypes
    clipboard.sourceAppBundleIdentifierOverride = nil
    clipboard.clearHooks()
  }

  private func startClipboard() {
    clipboard.restart()
  }

  func testChangesListenerAndAddHooks() {
    let hookExpectation = expectation(description: "Hook is called")
    clipboard.onNewCopy({ (_: CapturedCopy) in
      hookExpectation.fulfill()
    })
    startClipboard()
    pasteboard.declareTypes([.string], owner: nil)
    pasteboard.setString("bar", forType: .string)
    clock.fire()
    waitForExpectations(timeout: 0)
  }

  func testIgnoreStringWithOnlySpaces() {
    let hookExpectation = expectation(description: "Hook is called")
    hookExpectation.isInverted = true
    clipboard.onNewCopy({ (_: CapturedCopy) in
      hookExpectation.fulfill()
    })
    startClipboard()
    pasteboard.declareTypes([.string], owner: nil)
    pasteboard.setString(" ", forType: .string)
    clock.fire()
    waitForExpectations(timeout: 0)
  }

  func testIgnoreStringWithOnlyNewlines() {
    let hookExpectation = expectation(description: "Hook is called")
    hookExpectation.isInverted = true
    clipboard.onNewCopy({ (_: CapturedCopy) in
      hookExpectation.fulfill()
    })
    startClipboard()
    pasteboard.declareTypes([.string], owner: nil)
    pasteboard.setString("\n", forType: .string)
    clock.fire()
    waitForExpectations(timeout: 0)
  }

  func testDoesNotIgnoreRTF() {
    let hookExpectation = expectation(description: "Hook is called")
    clipboard.onNewCopy({ (_: CapturedCopy) in
      hookExpectation.fulfill()
    })
    startClipboard()
    let rtf = NSAttributedString(string: "foo").rtf(
      from: NSRange(0...2),
      documentAttributes: [:]
    )
    pasteboard.declareTypes([.rtf], owner: nil)
    pasteboard.setData(rtf, forType: .rtf)
    clock.fire()
    waitForExpectations(timeout: 0)
  }

  func testDoesNotIgnoreHTML() {
    let hookExpectation = expectation(description: "Hook is called")
    clipboard.onNewCopy({ (_: CapturedCopy) in
      hookExpectation.fulfill()
    })
    startClipboard()
    pasteboard.declareTypes([.html], owner: nil)
    pasteboard.setString("foo", forType: .html)
    clock.fire()
    waitForExpectations(timeout: 0)
  }

  func testIgnoreEventsIsEnabled() {
    Defaults[.ignoreEvents] = true

    let hookExpectation = expectation(description: "Hook is called")
    hookExpectation.isInverted = true
    clipboard.onNewCopy({ (_: CapturedCopy) in
      hookExpectation.fulfill()
    })
    startClipboard()
    pasteboard.declareTypes([.string], owner: nil)
    pasteboard.setString("foo", forType: .string)
    clock.fire()
    waitForExpectations(timeout: 0)
  }

  func testIgnoreOnlyNextEventIsEnabled() {
    Defaults[.ignoreEvents] = true
    Defaults[.ignoreOnlyNextEvent] = true

    let hookExpectation = expectation(description: "Hook is called")
    hookExpectation.isInverted = true
    clipboard.onNewCopy({ (_: CapturedCopy) in
      hookExpectation.fulfill()
    })
    startClipboard()
    pasteboard.declareTypes([.string], owner: nil)
    pasteboard.setString("foo", forType: .string)
    clock.fire()
    waitForExpectations(timeout: 0)

    XCTAssertFalse(Defaults[.ignoreEvents])
    XCTAssertFalse(Defaults[.ignoreOnlyNextEvent])
  }

  func testIgnoreApplication() {
    Defaults[.ignoredApps] = ["com.apple.dt.Xcode", "com.apple.finder"] // Finder is on Bitrise

    let hookExpectation = expectation(description: "Hook is called")
    hookExpectation.isInverted = true
    clipboard.onNewCopy({ (_: CapturedCopy) in
      hookExpectation.fulfill()
    })
    startClipboard()
    pasteboard.declareTypes([.string], owner: nil)
    pasteboard.setString("bar", forType: .string)
    clock.fire()
    waitForExpectations(timeout: 0)
  }

  func testIgnoreAllApplicationsExcept() {
    Defaults[.ignoreAllAppsExceptListed] = true
    Defaults[.ignoredApps] = ["com.apple.dt.Xcode", "com.apple.finder"] // Finder is on Bitrise

    let hookExpectation = expectation(description: "Hook is called")
    clipboard.onNewCopy({ (_: CapturedCopy) in
      hookExpectation.fulfill()
    })
    startClipboard()
    pasteboard.declareTypes([.string], owner: nil)
    pasteboard.setString("bar", forType: .string)
    clock.fire()
    waitForExpectations(timeout: 0)
  }

  func testIgnoreTransientTypes() {
    let hookExpectation = expectation(description: "Hook is called")
    hookExpectation.isInverted = true
    clipboard.onNewCopy({ (_: CapturedCopy) in
      hookExpectation.fulfill()
    })
    startClipboard()
    pasteboard.declareTypes([.string, transientType], owner: nil)
    pasteboard.setString("bar", forType: .string)
    clock.fire()
    waitForExpectations(timeout: 0)
  }

  func testIgnoreCustomTypes() {
    Defaults[.ignoredPasteboardTypes] = [customType.rawValue]

    let hookExpectation = expectation(description: "Hook is called")
    hookExpectation.isInverted = true
    clipboard.onNewCopy({ (_: CapturedCopy) in
      hookExpectation.fulfill()
    })
    startClipboard()
    pasteboard.declareTypes([.string, customType], owner: nil)
    pasteboard.setString("bar", forType: .string)
    clock.fire()
    waitForExpectations(timeout: 0)
  }

  func testIgnoreCopiesWithUnknownTypes() {
    let hookExpectation = expectation(description: "Hook is called")
    hookExpectation.isInverted = true
    clipboard.onNewCopy({ (_: CapturedCopy) in
      hookExpectation.fulfill()
    })
    startClipboard()
    pasteboard.declareTypes([unknownType], owner: nil)
    pasteboard.setString(" ", forType: unknownType)
    clock.fire()
    waitForExpectations(timeout: 0)
  }

  @MainActor
  func testCopy() {
    let imageData = image.tiffRepresentation!
    let contents = [
      HistoryItemContent(type: stringType.rawValue, value: "foo".data(using: .utf8)!),
      HistoryItemContent(type: tiffType.rawValue, value: imageData),
      HistoryItemContent(type: fileURLType.rawValue, value: "file://foo.bar".data(using: .utf8)!)
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.application = "com.foo.bar"
    clipboard.copy(item)
    XCTAssertEqual(pasteboard.string(forType: .string), "foo")
    XCTAssertEqual(pasteboard.data(forType: .tiff), imageData)
    XCTAssertEqual(pasteboard.string(forType: .fileURL), "file://foo.bar")
    XCTAssertEqual(pasteboard.string(forType: .fromLodge), "")
    XCTAssertEqual(pasteboard.string(forType: .source), "com.foo.bar")
  }

  @MainActor
  func testCopyWithoutFormatting() {
    let contents = [
      HistoryItemContent(type: stringType.rawValue, value: "foo".data(using: .utf8)!),
      HistoryItemContent(type: fileURLType.rawValue, value: "file://foo.bar".data(using: .utf8)!),
      HistoryItemContent(type: rtfType.rawValue,
                         value: coloredString.rtf(from: NSRange(location: 0, length: coloredString.length),
                                                  documentAttributes: [:]))
    ]
    let item = HistoryItem()
    Storage.shared.context.insert(item)
    item.contents = contents
    item.application = "com.foo.bar"
    clipboard.copy(item, removeFormatting: true)
    XCTAssertEqual(pasteboard.string(forType: .string), "foo")
    XCTAssertEqual(pasteboard.string(forType: .fromLodge), "")
    XCTAssertEqual(pasteboard.string(forType: .source), "com.foo.bar")
    XCTAssertEqual(pasteboard.string(forType: .fileURL), "file://foo.bar")
    XCTAssertNil(pasteboard.data(forType: .rtf))
  }

  func testHandlesItemsWithoutData() {
    let hookExpectation = expectation(description: "Hook is called")
    pasteboard.clearContents()
    clipboard.onNewCopy({ (_: CapturedCopy) in
      hookExpectation.fulfill()
    })
    startClipboard()
    pasteboard.declareTypes([.fileURL, .string], owner: nil)
    // fileURL is left without data
    pasteboard.setString("bar", forType: .string)
    clock.fire()
    waitForExpectations(timeout: 0)
  }

  func testMergesMultipleItems() {
    let hookExpectation = expectation(description: "Hook is called")
    clipboard.onNewCopy({ (item: CapturedCopy) in
      XCTAssertEqual(
        Set(item.contents.map({ $0.type })),
        Set([self.tiffType.rawValue, self.stringType.rawValue])
      )
      hookExpectation.fulfill()
    })

    let item1 = NSPasteboardItem()
    item1.setString("foo", forType: .string)
    let item2 = NSPasteboardItem()
    item2.setData(image.tiffRepresentation!, forType: .tiff)

    startClipboard()
    pasteboard.clearContents()
    pasteboard.writeObjects([item1, item2])

    clock.fire()
    waitForExpectations(timeout: 0)
  }

  func testRemovesDisabledTypes() {
    Defaults[.enabledPasteboardTypes] = [.fileURL]

    let hookExpectation = expectation(description: "Hook is called")
    clipboard.onNewCopy({ (item: CapturedCopy) in
      XCTAssertEqual(item.contents.map({ $0.type }), [self.fileURLType.rawValue])
      hookExpectation.fulfill()
    })

    let item = NSPasteboardItem()
    item.setString("foo", forType: .string)
    item.setData(image.tiffRepresentation!, forType: .tiff)
    item.setData("file://foo.bar".data(using: .utf8)!, forType: .fileURL)

    startClipboard()
    pasteboard.clearContents()
    pasteboard.writeObjects([item])

    clock.fire()
    waitForExpectations(timeout: 0)
  }

  func testRemovesDynamicTypes() {
    let hookExpectation = expectation(description: "Hook is called")
    clipboard.onNewCopy({ (item: CapturedCopy) in
      XCTAssertEqual(item.contents.map({ $0.type }), [self.stringType.rawValue])
      hookExpectation.fulfill()
    })

    let item = NSPasteboardItem()
    item.setString("foo", forType: .string)
    item.setData("".data(using: .utf8)!, forType: dynamicType)

    startClipboard()
    pasteboard.clearContents()
    pasteboard.writeObjects([item])

    clock.fire()
    waitForExpectations(timeout: 0)
  }
}
// swiftlint:enable type_body_length

@MainActor
final class ManualClipboardScheduler: ClipboardScheduling {
  private final class Token: ClipboardTimer {
    var cancelled = false
    func cancel() { cancelled = true }
  }
  private var action: (@MainActor () -> Void)?
  private var token: Token?
  private(set) var schedules = 0

  func schedule(interval: TimeInterval, action: @escaping @MainActor () -> Void) -> ClipboardTimer {
    schedules += 1
    self.action = action
    let token = Token()
    self.token = token
    return token
  }

  func fire() {
    guard token?.cancelled == false else { return }
    action?()
  }
}
