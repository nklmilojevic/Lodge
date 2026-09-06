extension String {
  func shortened(to maxLength: Int) -> String {
    // Read only the prefix. Counting the full string can block a large-text preview.
    String(prefix(max(0, maxLength)))
  }
}
