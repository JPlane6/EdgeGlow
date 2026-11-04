import AppKit

/// Self-updater: polls the latest GitHub release, downloads EdgeGlow.dmg, and swaps the installed app bundle
/// in place with a detached shell script once this process has exited.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case downloading(String)
        case installing(String)
        case failed(String)

        var text: String {
            switch self {
            case .idle: return ""
            case .checking: return "Checking for updates…"
            case .upToDate: return "EdgeGlow is up to date"
            case .downloading(let v): return "Downloading \(v)…"
            case .installing(let v): return "Installing \(v)…"
            case .failed(let why): return why
            }
        }

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .installing: return true
            default: return false
            }
        }
    }

    @Published private(set) var status: Status = .idle

    private static let latestURL = URL(string: "https://api.github.com/repos/JPlane6/EdgeGlow/releases/latest")!
    private static let assetName = "EdgeGlow.dmg"

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let assets: [Asset]
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Silent launch check. Only auto-installs a build that runs from an app bundle (not `swift run`).
    func checkOnLaunch() {
        guard Bundle.main.bundlePath.hasSuffix(".app") else { return }
        Task { await check(userInitiated: false) }
    }

    func checkNow() {
        Task { await check(userInitiated: true) }
    }

    private func check(userInitiated: Bool) async {
        guard !status.isBusy else { return }
        status = .checking
        do {
            var request = URLRequest(url: Self.latestURL, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("EdgeGlow/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message("Update server unavailable") }
            let release = try JSONDecoder().decode(Release.self, from: data)

            guard Self.isNewer(release.tag_name, than: currentVersion) else {
                status = userInitiated ? .upToDate : .idle
                return
            }
            guard let asset = release.assets.first(where: { $0.name == Self.assetName }) else {
                throw UpdateError.message("\(release.tag_name) has no \(Self.assetName)")
            }
            try await install(version: release.tag_name, from: asset.browser_download_url)
        } catch {
            // A silent launch check never nags; a manual check says what went wrong.
            status = userInitiated ? .failed((error as? UpdateError)?.description ?? "Update check failed") : .idle
        }
    }

    // MARK: Install

    private enum UpdateError: Error, CustomStringConvertible {
        case message(String)
        var description: String { if case .message(let m) = self { return m } else { return "" } }
    }

    private func install(version: String, from url: URL) async throws {
        status = .downloading(version)
        let (tmp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.message("Download failed") }

        let dmg = URL(fileURLWithPath: "/tmp/EdgeGlow-update.dmg")
        try? FileManager.default.removeItem(at: dmg)
        try FileManager.default.moveItem(at: tmp, to: dmg)

        let appPath = Bundle.main.bundlePath
        guard FileManager.default.isWritableFile(atPath: (appPath as NSString).deletingLastPathComponent) else {
            throw UpdateError.message("Can't write to \((appPath as NSString).deletingLastPathComponent)")
        }

        status = .installing(version)
        let script = URL(fileURLWithPath: "/tmp/EdgeGlow-update.sh")
        try Self.script.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), dmg.path, appPath]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        try task.run()

        // The script waits for this pid to disappear, so quit now.
        NSApp.terminate(nil)
    }

    /// Args: <pid to wait for> <dmg> <installed .app path>. The old app is only replaced after the new one was
    /// copied completely, and the app is relaunched whether or not the update worked.
    private static let script = """
    #!/bin/bash
    PID="$1"; DMG="$2"; APP="$3"
    MOUNT="$(mktemp -d /tmp/edgeglow-mount.XXXXXX)"
    STAGE="$(dirname "$APP")/.EdgeGlow-new.app"

    for _ in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done

    if hdiutil attach "$DMG" -nobrowse -readonly -noverify -noautoopen -mountpoint "$MOUNT" >/dev/null 2>&1; then
        NEW="$(find "$MOUNT" -maxdepth 1 -name '*.app' | head -n 1)"
        if [ -n "$NEW" ]; then
            rm -rf "$STAGE"
            if rsync -a "$NEW/" "$STAGE/"; then
                xattr -cr "$STAGE"
                rm -rf "$APP" && mv "$STAGE" "$APP"
            fi
            rm -rf "$STAGE"
        fi
        hdiutil detach "$MOUNT" -quiet -force >/dev/null 2>&1
    fi
    rmdir "$MOUNT" 2>/dev/null
    rm -f "$DMG"

    xattr -cr "$APP" 2>/dev/null
    /usr/bin/open "$APP"
    rm -f "$0"
    """

    // MARK: Versions

    /// "v1.2.10" > "1.2.9". Non-numeric suffixes ("-beta") are ignored.
    nonisolated static func isNewer(_ tag: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                .split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(tag), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
