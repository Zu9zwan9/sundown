import Foundation

/// Running containers, and whether they look like they belong to this session.
///
/// Silent when Docker isn't installed or isn't running — an absent capability
/// should produce an absent section, not an error.
struct ContainerScanner: Sendable {

    struct Container: Sendable, Hashable {
        let id: String
        let name: String
        let image: String
        let status: String
        /// Started by dev tooling rather than being long-lived infrastructure.
        let isEphemeral: Bool
    }

    /// Name and image fragments that mean "spun up for development".
    /// A container matching none of these is still listed, just not preselected —
    /// your Postgres has been up for three weeks and you meant it to be.
    static let ephemeralMarkers = [
        "devcontainer", "vsc-", "vscode", "codespace", "sandbox",
        "mcp", "claude", "agent-", "-agent", "playwright", "browserless",
    ]

    private static let dockerPaths = [
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
        "/Applications/Docker.app/Contents/Resources/bin/docker",
        "/usr/bin/docker",
    ]

    func scan() -> [Container] {
        guard let docker = Shell.locate(Self.dockerPaths) else { return [] }

        // Unit separator between fields: container names and image tags can
        // legally contain most other things, but never \u{1F}.
        let format = "{{.ID}}\u{1F}{{.Names}}\u{1F}{{.Image}}\u{1F}{{.Status}}"
        guard let result = Shell.run(docker, ["ps", "--no-trunc", "--format", format]),
            result.status == 0
        else { return [] }

        return result.output
            .split(separator: "\n")
            .compactMap { line in
                let fields = line.split(separator: "\u{1F}", omittingEmptySubsequences: false)
                guard fields.count >= 4 else { return nil }

                let name = String(fields[1])
                let image = String(fields[2])
                let haystack = (name + " " + image).lowercased()

                return Container(
                    id: String(fields[0].prefix(12)),
                    name: name,
                    image: image,
                    status: String(fields[3]),
                    isEphemeral: Self.ephemeralMarkers.contains { haystack.contains($0) }
                )
            }
    }

    /// `docker stop` with a grace period. Returns false if Docker refused.
    func stop(id: String, gracePeriod: Int = 5) -> Bool {
        guard let docker = Shell.locate(Self.dockerPaths) else { return false }
        let result = Shell.run(
            docker, ["stop", "-t", String(gracePeriod), id],
            timeout: TimeInterval(gracePeriod) + 5
        )
        return result?.status == 0
    }
}
