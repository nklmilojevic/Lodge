cask "lodge" do
  version "1.0.0"
  sha256 "b70dec353f34f3dfd98615163ca81000fe46a010836d0a2cc2d64653651fbf6a"

  url "https://github.com/nklmilojevic/Lodge/releases/download/v#{version}/Lodge.dmg"
  name "Lodge"
  desc "Clipboard manager for macOS"
  homepage "https://github.com/nklmilojevic/Lodge"

  depends_on macos: ">= :sonoma"

  app "Lodge.app"

  zap trash: [
    "~/Library/Application Support/Lodge",
    "~/Library/Preferences/com.nklmilojevic.Lodge.plist",
  ]
end
