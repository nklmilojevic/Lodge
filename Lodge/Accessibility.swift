import AppKit

@MainActor
struct Accessibility {
  static var allowed: Bool { AXIsProcessTrustedWithOptions(nil) }
  private static var hasExplainedPermission = false

  @discardableResult
  static func check() -> Bool {
    guard !allowed else { return true }
    guard !hasExplainedPermission else { return false }
    hasExplainedPermission = true

    let settings = NSLocalizedString("system_settings_name", comment: "")
    let pane = NSLocalizedString("system_settings_pane", comment: "")
    let comment = NSLocalizedString("accessibility_alert_comment", comment: "")
      .replacingOccurrences(of: "{settings}", with: settings)
      .replacingOccurrences(of: "{pane}", with: pane)

    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = NSLocalizedString("accessibility_alert_message", comment: "")
    alert.informativeText = comment
    alert.addButton(withTitle: NSLocalizedString("accessibility_alert_open", comment: ""))
    alert.addButton(withTitle: NSLocalizedString("accessibility_alert_deny", comment: ""))

    if alert.runModal() == .alertFirstButtonReturn,
       let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
      NSWorkspace.shared.open(url)
    }
    return false
  }
}
