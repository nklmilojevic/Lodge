import Foundation
import SwiftData

@Model
class HistoryItemContent {
  var type: String = ""
  var fingerprint: String = ""

  var contentDigest: String {
    fingerprint.isEmpty ? ContentProcessor.fingerprint(ContentSnapshot(type: type, value: value)) : fingerprint
  }
  @Attribute(.externalStorage) var value: Data?

  @Relationship
  var item: HistoryItem?

  init(type: String, value: Data? = nil) {
    self.type = type
    self.value = value
  }
}
