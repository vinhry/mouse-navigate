# Written by the release workflow of vinhry/mouse-navigate from packaging/homebrew/ there,
# with the version and the SHA-256 of the zip it has just published. Change it there.
cask "mouse-navigate" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/vinhry/mouse-navigate/releases/download/v#{version}/MouseNavigate.zip"
  name "MouseNavigate"
  desc "Side-button actions, touch gestures and keyboard cursor control for the mouse"
  homepage "https://github.com/vinhry/mouse-navigate"

  livecheck do
    url :url
    strategy :github_latest
  end

  # It installs its own updates from GitHub Releases, verified against its signature.
  auto_updates true
  depends_on macos: :ventura

  app "MouseNavigate.app"

  uninstall quit: "com.vinhry.MouseNavigate"

  zap trash: [
    "~/Library/Caches/com.vinhry.MouseNavigate",
    "~/Library/Preferences/com.vinhry.MouseNavigate.plist",
  ]
end
