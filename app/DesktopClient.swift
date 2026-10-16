import Foundation
import AppKit

enum DesktopClient {
    static let bundleID = "com.openai.codex"
    static let displayName = "Codex"

    static var applications: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    }

    static func running() -> Bool { !applications.isEmpty }

    /// A cancelled or unsuccessful quit must leave the login files untouched.
    static func quit() -> Bool {
        let runningApps = applications
        guard !runningApps.isEmpty else { return true }
        for app in runningApps { _ = app.terminate() }
        for _ in 0..<60 {
            if !running() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return !running()
    }

    static func open() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-b", bundleID]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit() } catch { return false }
        guard process.terminationStatus == 0 else { return false }
        for _ in 0..<50 {
            if let app = applications.first {
                _ = app.activate(options: [])
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }
}
