cask "compass" do
  version :latest
  sha256 :no_check

  url "https://github.com/jtrefon/compass/releases/latest/download/compass.dmg"
  name "Compass"
  desc "Native AI-powered IDE for macOS"
  homepage "https://github.com/jtrefon/compass"

  app "Compass.app"
end
