import AppKit

/// Manual "Check for Updates…" against the GitHub Releases API — no
/// background polling or timers, only fired on explicit user request from
/// the status-item menu or the Settings window.
enum UpdateChecker {
    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/quangnd159/nickel/releases/latest")!

    static func check() {
        let task = URLSession.shared.dataTask(with: latestReleaseURL) { data, response, error in
            DispatchQueue.main.async {
                handleResponse(data: data, response: response, error: error)
            }
        }
        task.resume()
    }

    private static func handleResponse(data: Data?, response: URLResponse?, error: Error?) {
        if let error {
            presentError(error.localizedDescription)
            return
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            presentNoReleases()
            return
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
            let status = (response as? HTTPURLResponse)?.statusCode
            presentError(status.map { "The server responded with status \($0)." } ?? "The server returned an unexpected response.")
            return
        }

        do {
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latestVersion = normalizedVersion(release.tagName)
            let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"

            if compareVersions(latestVersion, isNewerThan: currentVersion) {
                presentUpdateAvailable(version: latestVersion, releaseURL: release.htmlURL)
            } else {
                presentUpToDate()
            }
        } catch {
            presentError(error.localizedDescription)
        }
    }

    /// "v1.2.3" -> "1.2.3"; leaves non-prefixed tags alone. Only strips the
    /// `v` when what follows starts with a digit, so "version1" is untouched.
    static func normalizedVersion(_ tag: String) -> String {
        guard tag.hasPrefix("v"), let first = tag.dropFirst().first, first.isNumber else {
            return tag
        }
        return String(tag.dropFirst())
    }

    /// Numeric, component-wise comparison (`"1.2.0"` vs. `"1.10.0"`), so a
    /// naive string compare can't misorder double-digit components. Missing
    /// trailing components are treated as `0` (`"1.2"` == `"1.2.0"`).
    /// Non-numeric suffixes inside a component contribute their leading
    /// digits (`"1-beta"` -> `1`); a fully non-numeric component counts as `0`.
    static func compareVersions(_ lhs: String, isNewerThan rhs: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let lhsParts = parts(lhs)
        let rhsParts = parts(rhs)
        let count = max(lhsParts.count, rhsParts.count)

        for index in 0..<count {
            let lhsValue = index < lhsParts.count ? lhsParts[index] : 0
            let rhsValue = index < rhsParts.count ? rhsParts[index] : 0
            if lhsValue != rhsValue {
                return lhsValue > rhsValue
            }
        }
        return false
    }

    /// Only ever open the release page we expect: https, on github.com or a
    /// subdomain. Anything else in `html_url` means the response was tampered
    /// with or the API changed shape — don't hand it to the OS.
    static func validatedReleaseURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "github.com" || host.hasSuffix(".github.com") else {
            return nil
        }
        return url
    }

    private static func presentUpdateAvailable(version: String, releaseURL: String) {
        AppActivation.activate()
        let alert = NSAlert()
        alert.messageText = "Nickel \(version) is available."
        alert.informativeText = "You're currently running an older version."
        alert.addButton(withTitle: "View Release")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = validatedReleaseURL(releaseURL) {
                NSWorkspace.shared.open(url)
            } else {
                presentError("The release page address was unexpected.")
            }
        }
    }

    private static func presentUpToDate() {
        AppActivation.activate()
        let alert = NSAlert()
        alert.messageText = "You're up to date."
        alert.informativeText = "Nickel is on the latest version."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func presentNoReleases() {
        AppActivation.activate()
        let alert = NSAlert()
        alert.messageText = "You're up to date."
        alert.informativeText = "No releases have been published yet."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private static func presentError(_ message: String) {
        AppActivation.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't check for updates."
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
