import AppKit
import Darwin
import Foundation

/// The user-facing application behind an audio-producing process.
struct ResolvedApp: Hashable {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let icon: NSImage?

    static func == (lhs: ResolvedApp, rhs: ResolvedApp) -> Bool {
        lhs.pid == rhs.pid && lhs.name == rhs.name && lhs.bundleID == rhs.bundleID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(bundleID)
    }
}

/// Maps a Core Audio client process to the app the user would recognise.
/// Browsers and Electron apps play audio from helper processes (Chrome Helper,
/// com.apple.WebKit.GPU, …), so we walk up to the "responsible" process the same
/// way TCC does, then fall back to the outermost `.app` bundle on the path.
enum AppResolver {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    private static let responsiblePID: ResponsibleFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()

    static func resolve(pid: pid_t, bundleID: String?) -> ResolvedApp {
        var candidates: [pid_t] = []
        if let responsible = responsiblePID?(pid), responsible > 0, responsible != pid {
            candidates.append(responsible)
        }
        candidates.append(pid)

        for candidate in candidates {
            if let app = NSRunningApplication(processIdentifier: candidate), app.activationPolicy != .prohibited {
                return ResolvedApp(pid: candidate, name: app.localizedName ?? fallbackName(pid: candidate, bundleID: bundleID),
                                   bundleID: app.bundleIdentifier, icon: app.icon)
            }
        }

        // Not a LaunchServices-visible app; look for the outermost .app on the executable path.
        if let path = executablePath(pid: pid), let bundleURL = outermostAppBundle(in: path) {
            let bundle = Bundle(url: bundleURL)
            let name = bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? bundleURL.deletingPathExtension().lastPathComponent
            return ResolvedApp(pid: pid, name: name, bundleID: bundle?.bundleIdentifier ?? bundleID,
                               icon: NSWorkspace.shared.icon(forFile: bundleURL.path))
        }

        return ResolvedApp(pid: pid, name: fallbackName(pid: pid, bundleID: bundleID), bundleID: bundleID, icon: nil)
    }

    private static func fallbackName(pid: pid_t, bundleID: String?) -> String {
        if let path = executablePath(pid: pid) { return URL(fileURLWithPath: path).lastPathComponent }
        return bundleID ?? "Process \(pid)"
    }

    private static func executablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(PATH_MAX))  // PROC_PIDPATHINFO_MAXSIZE
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func outermostAppBundle(in path: String) -> URL? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return URL(fileURLWithPath: components[...index].joined(separator: "/"))
    }
}
