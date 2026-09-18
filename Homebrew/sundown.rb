# Homebrew formula for the Sundown CLI.
#
# This file belongs in a tap repository, not here — see Homebrew/README.md.
# It lives in-tree so the formula is versioned alongside the code it builds.
#
# Only the CLI is tapped. The menu bar app needs a signed, notarised bundle
# and belongs in a GitHub release, not a formula.

class Sundown < Formula
  desc "Reap orphaned MCP servers and agent processes on macOS"
  homepage "https://github.com/Zu9zwan9/sundown"
  license "MIT"
  url "https://github.com/Zu9zwan9/sundown/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "e0f9bf096c3d2b3b6654a2ad606a260e536b673fe19087adac226b2b143003f5"
  head "https://github.com/Zu9zwan9/sundown.git", branch: "main"

  # No `url`/`sha256` yet, on purpose. There is no tag to point at, so any
  # pair written here is either a 404 or a placeholder that fails with a
  # checksum mismatch — the two worst ways to greet a first install.
  #
  # Head-only is a valid formula: `brew install --HEAD` works the moment the
  # repo is public, and `brew install` without it says "no stable download",
  # which is true. Add the stable pair when you tag — see README.md step 3.

  depends_on xcode: ["15.0", :build]
  depends_on macos: :sonoma # macOS 14, for MenuBarExtra and @Observable

  def install
    # --disable-sandbox: SwiftPM's own sandbox conflicts with Homebrew's,
    # which is the usual cause of a "Operation not permitted" build failure.
    system "swift", "build",
           "--disable-sandbox",
           "-c", "release",
           "--product", "sundown"
    bin.install ".build/release/sundown"
  end

  test do
    # --version needs no processes, no config, and no permissions, so it is
    # the only thing safe to assert in a sandboxed CI test.
    assert_match "sundown", shell_output("#{bin}/sundown --version")

    # --dry-run must never terminate anything. If this ever exits non-zero on
    # a clean machine, the safety default has regressed.
    system bin/"sundown", "--dry-run", "--quiet"
  end
end
