import Cocoa

@MainActor
class About {
  private let familyCredits = NSAttributedString(
    string: "Special thank you to Tonia, Anna & Guy! ❤️",
    attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor]
  )

  private var kossCredits: NSMutableAttributedString {
    let string = NSMutableAttributedString(string: "Kudos to Sasha Koss for help! 🏂",
                                           attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor])
    string.addAttribute(.link, value: "https://koss.nocorp.me", range: NSRange(location: 9, length: 10))
    return string
  }

  private var links: NSMutableAttributedString {
    let string = NSMutableAttributedString(string: "GitHub",
                                           attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor])
    string.addAttribute(.link, value: "https://github.com/nklmilojevic/Lodge", range: NSRange(location: 0, length: 6))
    return string
  }

  private var semanticCredits: NSMutableAttributedString {
    let text = "Semantic search uses EmbeddingGemma 2 in FluidInference's Core ML conversion, and code adapted from DigUp."
    let string = NSMutableAttributedString(string: text,
                                           attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor])
    let links = [("EmbeddingGemma 2", "https://huggingface.co/google/embeddinggemma-2"),
                 ("FluidInference's Core ML conversion", "https://huggingface.co/FluidInference/embeddinggemma-2-coreml"),
                 ("DigUp", "https://github.com/ARahim3/DigUp")]
    for (name, url) in links {
      string.addAttribute(.link, value: url, range: (text as NSString).range(of: name))
    }
    return string
  }

  private var credits: NSMutableAttributedString {
    let credits = NSMutableAttributedString(string: "",
                                            attributes: [NSAttributedString.Key.foregroundColor: NSColor.labelColor])
    credits.append(links)
    credits.append(NSAttributedString(string: "\n\n"))
    credits.append(kossCredits)
    credits.append(NSAttributedString(string: "\n"))
    credits.append(familyCredits)
    credits.append(NSAttributedString(string: "\n\n"))
    credits.append(semanticCredits)
    credits.setAlignment(.center, range: NSRange(location: 0, length: credits.length))
    return credits
  }

  @objc
  func openAbout(_ sender: NSMenuItem?) {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(options: [NSApplication.AboutPanelOptionKey.credits: credits])
  }
}
