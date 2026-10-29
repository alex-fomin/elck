import AppKit
import CryptoKit
import Darwin
import ElckCore
import LocalAuthentication
import UniformTypeIdentifiers

private let delegate = AppDelegate()

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}

private struct Manifest: Codable {
    var container: String
    var temp: String
}

private struct WaitCLI {
    var bundleIDs: [String]
    var relativePath: String
    var arguments: [String]
}

private let waitCLIs = [
    WaitCLI(bundleIDs: ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"], relativePath: "Contents/Resources/app/bin/code", arguments: ["--wait"]),
    WaitCLI(bundleIDs: ["com.todesktop.230313mzl4w4u92"], relativePath: "Contents/Resources/app/bin/cursor", arguments: ["--wait"]),
    WaitCLI(bundleIDs: ["com.sublimetext.4", "com.sublimetext.3"], relativePath: "Contents/SharedSupport/bin/subl", arguments: ["-w"]),
    WaitCLI(bundleIDs: ["com.barebones.bbedit"], relativePath: "Contents/Helpers/bbedit", arguments: ["--wait"]),
]

final class Session {
    let id = UUID()
    let containerURL: URL
    let tempURL: URL
    let fileKey: SymmetricKey
    let wrapHeader: Data

    init(containerURL: URL, tempURL: URL, fileKey: SymmetricKey, wrapHeader: Data) {
        self.containerURL = containerURL
        self.tempURL = tempURL
        self.fileKey = fileKey
        self.wrapHeader = wrapHeader
    }
    var fd: Int32 = -1
    var source: DispatchSourceFileSystemObject?
    var debounce: DispatchWorkItem?
    var process: Process?
    var watchedPID: pid_t = 0
    var observer: NSObjectProtocol?
    var launchedAt = Date()
    var handedOff = false
    var finished = false
    var editorBundleID: String?
    var waitsForCLI = false
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var sessions: [UUID: Session] = [:]
    private var serviceBusy = false
    private var pending = 0
    private var launchGraceDone = false
    private var didWork = false
    private var aboutShown = false
    private var aboutCloseObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        claimElckFiles()
        recover()
        openArguments()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.launchGraceDone = true
            self?.quitIfIdle()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            accept(url)
        }
    }

    @objc(sealFiles:userData:error:)
    func sealFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>?) {
        didWork = true
        serviceBusy = true
        defer {
            serviceBusy = false
            quitIfIdle()
        }
        let urls = fileURLs(from: pboard)
        guard !urls.isEmpty else {
            error?.pointee = "No files" as NSString
            return
        }
        var failures: [String] = []
        for url in urls {
            do {
                try seal(url)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            error?.pointee = failures.joined(separator: "\n") as NSString
        }
    }

    private func accept(_ url: URL) {
        didWork = true
        pending += 1
        defer {
            pending -= 1
            quitIfIdle()
        }
        if url.pathExtension.lowercased() == "elck" {
            openElck(url)
        } else {
            do {
                try seal(url)
            } catch {
                alert(error.localizedDescription)
            }
        }
    }

    private func openArguments() {
        for arg in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: arg)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            accept(url)
        }
    }

    private func seal(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return }
        if url.pathExtension.lowercased() == "elck" { return }
        let dest = url.appendingPathExtension("elck")
        if FileManager.default.fileExists(atPath: dest.path) {
            throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: dest.path])
        }
        // ponytail: whole file in memory. Stream if multi-GB files show up.
        let plaintext = try Data(contentsOf: url)
        let sealed = try ElckFormat.seal(plaintext: plaintext, to: try EnclaveKey.publicKey())
        try sealed.write(to: dest, options: .atomic)
        do {
            try removeOriginal(url)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            throw error
        }
    }

    private func removeOriginal(_ url: URL) throws {
        var coordinationError: NSError?
        var deleteError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { url in
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                deleteError = error
            }
        }
        if let coordinationError { throw coordinationError }
        if let deleteError { throw deleteError }
    }

    private func openElck(_ url: URL) {
        if sessions.values.contains(where: { $0.containerURL.path == url.path }) { return }
        do {
            let container = try Data(contentsOf: url)
            let opened = try ElckFormat.open(container: container) { ephemeral in
                try EnclaveKey.agree(with: ephemeral, reason: "open \(url.lastPathComponent)")
            }
            let session = try makeSession(containerURL: url, opened: opened, plaintext: opened.plaintext)
            start(session)
        } catch {
            if !isCancel(error) { alert(error.localizedDescription) }
        }
    }

    private func makeSession(containerURL: URL, opened: ElckFormat.Opened, plaintext: Data) throws -> Session {
        let root = support.appendingPathComponent("open", isDirectory: true)
        let dir = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var backup = URLResourceValues()
        backup.isExcludedFromBackup = true
        var mutable = dir
        try mutable.setResourceValues(backup)
        let name = innerName(containerURL)
        let temp = dir.appendingPathComponent(name.isEmpty ? "file" : name)
        try plaintext.write(to: temp, options: .atomic)
        return Session(containerURL: containerURL, tempURL: temp, fileKey: opened.fileKey, wrapHeader: opened.wrapHeader)
    }

    private func start(_ session: Session) {
        sessions[session.id] = session
        writeManifest(session)
        arm(session)
        launchEditor(session)
    }

    private func arm(_ session: Session) {
        let fd = open(session.tempURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        session.fd = fd
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self, weak session] in
            guard let self, let session, !session.finished else { return }
            let events = source.data
            if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
                source.cancel()
                DispatchQueue.main.async {
                    if !session.finished, FileManager.default.fileExists(atPath: session.tempURL.path) {
                        self.arm(session)
                    }
                }
            }
            DispatchQueue.main.async { self.scheduleFlush(session) }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        session.source = source
    }

    private func scheduleFlush(_ session: Session) {
        session.debounce?.cancel()
        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session, !session.finished else { return }
            self.flush(session)
        }
        session.debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func flush(_ session: Session) {
        guard let plaintext = try? Data(contentsOf: session.tempURL) else { return }
        guard let sealed = try? ElckFormat.write(plaintext: plaintext, fileKey: session.fileKey, wrapHeader: session.wrapHeader) else { return }
        try? sealed.write(to: session.containerURL, options: .atomic)
    }

    private func launchEditor(_ session: Session) {
        if let cli = waitCommand(for: session.tempURL) {
            let process = Process()
            process.executableURL = cli.binary
            process.arguments = cli.arguments + [session.tempURL.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async { self?.finish(session.id) }
            }
            session.process = process
            session.waitsForCLI = true
            session.launchedAt = Date()
            do {
                try process.run()
                return
            } catch {
                alert(error.localizedDescription)
            }
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: session.tempURL) else {
            alert("No application for .\(session.tempURL.pathExtension)")
            finish(session.id)
            return
        }
        session.editorBundleID = Bundle(url: appURL)?.bundleIdentifier
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        session.launchedAt = Date()
        NSWorkspace.shared.open([session.tempURL], withApplicationAt: appURL, configuration: config) { [weak self] running, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let running, !running.isTerminated {
                    running.activate(options: [.activateAllWindows])
                    self.observe(running, session: session)
                    return
                }
                let bundleID = Bundle(url: appURL)?.bundleIdentifier
                if let existing = NSWorkspace.shared.runningApplications.first(where: {
                    $0.bundleIdentifier == bundleID && !$0.isTerminated
                }) {
                    existing.activate(options: [.activateAllWindows])
                    session.handedOff = true
                    self.observe(existing, session: session)
                    return
                }
                self.alert(error?.localizedDescription ?? "Could not open the file")
                self.finish(session.id)
            }
        }
    }

    private func observe(_ app: NSRunningApplication, session: Session) {
        if let observer = session.observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        session.watchedPID = app.processIdentifier
        session.observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let quit = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  quit.processIdentifier == session.watchedPID else { return }
            self?.editorExited(session.id, app: quit)
        }
    }

    private func editorExited(_ id: UUID, app: NSRunningApplication) {
        guard let session = sessions[id], !session.finished else { return }
        if session.waitsForCLI {
            finish(id)
            return
        }
        let bundle = session.editorBundleID ?? app.bundleIdentifier
        if let other = runningApp(bundleID: bundle, besides: app.processIdentifier) {
            session.handedOff = true
            observe(other, session: session)
            return
        }
        finish(id)
    }

    private func finish(_ id: UUID) {
        guard let session = sessions[id], !session.finished else { return }
        session.finished = true
        session.debounce?.cancel()
        flush(session)
        session.source?.cancel()
        session.process?.terminationHandler = nil
        if let observer = session.observer {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        shred(session.tempURL)
        try? FileManager.default.removeItem(at: session.tempURL.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: manifestURL(session.id))
        sessions.removeValue(forKey: id)
        quitIfIdle()
    }

    private func recover() {
        let dir = support.appendingPathComponent("sessions", isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in names where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { continue }
            let temp = URL(fileURLWithPath: manifest.temp)
            let container = URL(fileURLWithPath: manifest.container)
            guard FileManager.default.fileExists(atPath: temp.path) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            do {
                let plaintext = try Data(contentsOf: temp)
                let opened = try ElckFormat.sealKeepingKey(plaintext: plaintext, to: try EnclaveKey.publicKey())
                let sealed = try ElckFormat.write(plaintext: plaintext, fileKey: opened.fileKey, wrapHeader: opened.wrapHeader)
                try sealed.write(to: container, options: .atomic)
                let bundle = editorBundleID(for: temp)
                if let editor = runningApp(bundleID: bundle, besides: 0) ?? holder(of: temp) {
                    let session = Session(containerURL: container, tempURL: temp, fileKey: opened.fileKey, wrapHeader: opened.wrapHeader)
                    session.editorBundleID = bundle
                    session.handedOff = true
                    sessions[session.id] = session
                    writeManifest(session)
                    try? FileManager.default.removeItem(at: url)
                    arm(session)
                    observe(editor, session: session)
                } else {
                    shred(temp)
                    try? FileManager.default.removeItem(at: temp.deletingLastPathComponent())
                    try? FileManager.default.removeItem(at: url)
                }
            } catch {
                alert(error.localizedDescription)
            }
        }
    }

    private func writeManifest(_ session: Session) {
        let url = manifestURL(session.id)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let manifest = Manifest(container: session.containerURL.path, temp: session.tempURL.path)
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func quitIfIdle() {
        guard launchGraceDone, sessions.isEmpty, !serviceBusy, pending == 0 else { return }
        if !didWork && !aboutShown {
            showAbout()
            return
        }
        if NSApp.windows.contains(where: \.isVisible) { return }
        NSApp.terminate(nil)
    }

    private func showAbout() {
        aboutShown = true
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let credits = NSAttributedString(
            string: "Finder → Services → Seal with elck.\nOpening a .elck file asks for Touch ID.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: style,
            ]
        )
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        guard aboutCloseObserver == nil else { return }
        aboutCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.aboutShown else { return }
                guard !NSApp.windows.contains(where: \.isVisible) else { return }
                guard self.sessions.isEmpty, self.pending == 0, !self.serviceBusy else { return }
                NSApp.terminate(nil)
            }
        }
    }

    private func claimElckFiles() {
        guard let type = UTType(filenameExtension: "elck") else { return }
        if NSWorkspace.shared.urlForApplication(toOpen: type) != Bundle.main.bundleURL {
            NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: type)
        }
    }

    private var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("elck", isDirectory: true)
    }

    private func manifestURL(_ id: UUID) -> URL {
        support.appendingPathComponent("sessions", isDirectory: true).appendingPathComponent("\(id.uuidString).json")
    }

    private func alert(_ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "elck"
        alert.informativeText = text
        alert.runModal()
    }
}

private func editorBundleID(for file: URL) -> String? {
    guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: file) else { return nil }
    return Bundle(url: appURL)?.bundleIdentifier
}

private func runningApp(bundleID: String?, besides pid: pid_t) -> NSRunningApplication? {
    guard let bundleID else { return nil }
    return NSWorkspace.shared.runningApplications.first {
        $0.bundleIdentifier == bundleID && !$0.isTerminated && $0.processIdentifier != pid
    }
}

private func holder(of file: URL) -> NSRunningApplication? {
    guard let pid = pidsHolding(file.path).first else { return nil }
    let app = NSRunningApplication(processIdentifier: pid)
    return app?.isTerminated == false ? app : nil
}

private func fileURLs(from pboard: NSPasteboard) -> [URL] {
    if let paths = pboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType")) as? [String], !paths.isEmpty {
        return paths.map { URL(fileURLWithPath: $0) }
    }
    return pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
}

private func innerName(_ url: URL) -> String {
    let name = url.lastPathComponent
    if name.lowercased().hasSuffix(".elck") {
        return String(name.dropLast(".elck".count))
    }
    return name
}

private func waitCommand(for file: URL) -> (binary: URL, arguments: [String])? {
    guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: file),
          let id = Bundle(url: appURL)?.bundleIdentifier,
          let spec = waitCLIs.first(where: { $0.bundleIDs.contains(id) }) else { return nil }
    let binary = appURL.appendingPathComponent(spec.relativePath)
    guard FileManager.default.isExecutableFile(atPath: binary.path) else { return nil }
    return (binary, spec.arguments)
}

private func pidsHolding(_ path: String) -> [pid_t] {
    let bytes = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, 0, nil, 0)
    guard bytes > 0 else { return [] }
    var buffer = [pid_t](repeating: 0, count: Int(bytes) / MemoryLayout<pid_t>.size)
    let filled = proc_listpidspath(UInt32(PROC_ALL_PIDS), 0, path, 0, &buffer, bytes)
    guard filled > 0 else { return [] }
    let count = Int(filled) / MemoryLayout<pid_t>.size
    return Array(buffer.prefix(count)).filter { $0 != getpid() && $0 != 0 }
}

// ponytail: overwrite then unlink. APFS copy-on-write may keep the old blocks.
private func shred(_ url: URL) {
    if let handle = try? FileHandle(forWritingTo: url) {
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)
        let zeros = Data(count: 64 * 1024)
        var left = size
        while left > 0 {
            let n = Int(min(UInt64(zeros.count), left))
            try? handle.write(contentsOf: zeros.prefix(n))
            left -= UInt64(n)
        }
        try? handle.synchronize()
        try? handle.close()
    }
    try? FileManager.default.removeItem(at: url)
}

private func isCancel(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == LAError.errorDomain {
        return ns.code == LAError.userCancel.rawValue
            || ns.code == LAError.appCancel.rawValue
            || ns.code == LAError.systemCancel.rawValue
    }
    return false
}
