import SwiftUI
import UIKit
import Foundation
import UserNotifications

// MARK: - Model types

struct DLMeta: Codable {
    var id: String
    var url: String
    var filename: String
    var total: Int64          // 0 = unknown
    var chunkSize: Int64      // 0 = single stream
    var chunkCount: Int
    var ranged: Bool
    var cookie: String?
    var referer: String?
    var downloaded: [Int] = []   // chunks fully received (part file exists or already merged)
    var merged: [Int] = []       // chunks written into the final file
    var status: String = "downloading"   // downloading | paused | done | failed
    var error: String?
    var finalName: String?
    var addedAt: Date = Date()
}

struct DLRow: Identifiable {
    let id: String
    let filename: String
    let total: Int64
    let received: Int64
    let speed: Double
    let status: String
    let error: String?
    let fileURL: URL?
}

enum DLError: LocalizedError {
    case badResponse, noSpace
    var errorDescription: String? {
        switch self {
        case .badResponse: return "The server refused the request."
        case .noSpace: return "Not enough free storage on this iPhone."
        }
    }
}

// MARK: - Download manager
// Splits a file into many chunks, downloads them in parallel with HTTP range requests through a
// background URLSession (keeps going when you leave the app), writes every finished chunk straight
// into its position in the final file, and resumes after crashes or relaunches.

final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = DownloadManager()

    @Published var rows: [DLRow] = []
    @Published var lastMessage: String?
    var bgCompletion: (() -> Void)?

    private let opQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "kitsu.downloads"
        return q
    }()
    private let mergeQueue = DispatchQueue(label: "kitsu.merge", qos: .utility)

    // All of the following are only touched on opQueue.
    private var metas: [String: DLMeta] = [:]
    private var live: [String: URLSessionDownloadTask] = [:]
    private var partial: [String: [Int: Int64]] = [:]
    private var retries: [String: Int] = [:]
    private var lastBytes: [String: Int64] = [:]
    private var speeds: [String: Double] = [:]
    private var merging: Set<String> = []
    private var lastSample = Date()
    private var session: URLSession!

    // MARK: Paths

    static var docsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }
    private static var supportDir: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kitsu", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    private func partsDir(_ id: String) -> URL {
        Self.supportDir.appendingPathComponent("parts", isDirectory: true).appendingPathComponent(id, isDirectory: true)
    }
    private func workURL(_ m: DLMeta) -> URL {
        Self.supportDir.appendingPathComponent("work", isDirectory: true).appendingPathComponent(m.id + ".bin")
    }
    private var stateURL: URL { Self.supportDir.appendingPathComponent("downloads.json") }

    // MARK: Init

    override init() {
        super.init()
        try? FileManager.default.createDirectory(at: Self.docsDir, withIntermediateDirectories: true)
        loadState()
        let cfg = URLSessionConfiguration.background(withIdentifier: "com.browser.kitsu.downloads")
        cfg.httpMaximumConnectionsPerHost = 64   // the real limit is enforced in ensureTasks, so it can change live
        cfg.sessionSendsLaunchEvents = true
        cfg.isDiscretionary = false
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 60 * 60 * 24 * 7
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: opQueue)
        session.getAllTasks { [weak self] tasks in
            self?.opQueue.addOperation { self?.reconcile(existing: tasks) }
        }
        DispatchQueue.main.async {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.opQueue.addOperation { self?.refreshRows() }
            }
        }
    }

    // MARK: State

    private func loadState() {
        guard let d = try? Data(contentsOf: stateURL),
              let arr = try? JSONDecoder().decode([DLMeta].self, from: d) else { return }
        for m in arr { metas[m.id] = m }
    }

    private func saveState() {
        let arr = Array(metas.values).sorted { $0.addedAt < $1.addedAt }
        if let d = try? JSONEncoder().encode(arr) { try? d.write(to: stateURL, options: .atomic) }
    }

    func toast(_ s: String) {
        DispatchQueue.main.async {
            self.lastMessage = s
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) {
                if self.lastMessage == s { self.lastMessage = nil }
            }
        }
    }

    // MARK: Adding a download

    func add(url: URL, referer: String?, cookie: String?) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Task { [self] in
            do {
                var req = URLRequest(url: url)
                req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                req.timeoutInterval = 30
                if let c = cookie { req.setValue(c, forHTTPHeaderField: "Cookie") }
                if let r = referer { req.setValue(r, forHTTPHeaderField: "Referer") }
                let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                bytes.task.cancel()
                guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw DLError.badResponse
                }
                var total: Int64 = 0
                var ranged = false
                if http.statusCode == 206,
                   let cr = http.value(forHTTPHeaderField: "Content-Range"),
                   let slash = cr.lastIndex(of: "/"),
                   let t = Int64(cr[cr.index(after: slash)...]) {
                    total = t
                    ranged = true
                } else {
                    total = max(http.expectedContentLength, 0)
                }
                let finalURL = http.url ?? url
                let sameHost = finalURL.host == url.host
                let name = Self.filename(from: http, url: finalURL)

                if total > 0, let free = Self.freeSpace(), free < total + 200 * 1024 * 1024 {
                    throw DLError.noSpace
                }

                let mb: Int64 = 1024 * 1024
                var chunkSize: Int64 = 0
                var count = 1
                if ranged && total > 0 {
                    chunkSize = min(max(total / 32, 4 * mb), 64 * mb)
                    count = Int((total + chunkSize - 1) / chunkSize)
                }

                let meta = DLMeta(id: UUID().uuidString, url: finalURL.absoluteString, filename: name,
                                  total: total, chunkSize: chunkSize, chunkCount: count, ranged: ranged,
                                  cookie: sameHost ? cookie : nil, referer: referer)

                opQueue.addOperation { [self] in
                    let fm = FileManager.default
                    try? fm.createDirectory(at: partsDir(meta.id), withIntermediateDirectories: true)
                    try? fm.createDirectory(at: workURL(meta).deletingLastPathComponent(), withIntermediateDirectories: true)
                    fm.createFile(atPath: workURL(meta).path, contents: nil)
                    if total > 0, let h = try? FileHandle(forWritingTo: workURL(meta)) {
                        try? h.truncate(atOffset: UInt64(total))
                        try? h.close()
                    }
                    metas[meta.id] = meta
                    saveState()
                    ensureTasks(meta.id)
                    refreshRows()
                }
                if ranged {
                    toast("Downloading \(name) with \(count) parallel parts")
                } else {
                    toast("Downloading \(name) (server allows one connection only)")
                }
            } catch {
                toast("Couldn't start download: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Tasks

    private func chunkLength(_ m: DLMeta, _ idx: Int) -> Int64 {
        if !m.ranged || m.total <= 0 { return max(m.total, 0) }
        let start = Int64(idx) * m.chunkSize
        return min(m.chunkSize, m.total - start)
    }

    // Keeps at most `dlConnections` parts in flight for this download. Called whenever a part finishes,
    // so changing the setting takes effect on the next part that starts.
    private func ensureTasks(_ id: String) {
        guard let m = metas[id], m.status == "downloading",
              let url = URL(string: m.url) else { return }
        let stored = UserDefaults.standard.integer(forKey: "dlConnections")
        let limit = stored > 0 ? stored : 16
        var slots = limit - live.keys.filter { $0.hasPrefix(id + "|") }.count
        if slots <= 0 { return }
        let have = Set(m.downloaded)
        for idx in 0..<m.chunkCount where !have.contains(idx) {
            if slots <= 0 { break }
            let key = id + "|" + String(idx)
            if live[key] != nil { continue }
            var req = URLRequest(url: url)
            if m.ranged && m.total > 0 {
                let start = Int64(idx) * m.chunkSize
                let end = start + chunkLength(m, idx) - 1
                req.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            }
            if let c = m.cookie { req.setValue(c, forHTTPHeaderField: "Cookie") }
            if let r = m.referer { req.setValue(r, forHTTPHeaderField: "Referer") }
            let t = session.downloadTask(with: req)
            t.taskDescription = key
            live[key] = t
            t.resume()   // new tasks start suspended
            slots -= 1
        }
    }

    private func reconcile(existing tasks: [URLSessionTask]) {
        for t in tasks {
            if let dt = t as? URLSessionDownloadTask, let d = dt.taskDescription { live[d] = dt }
        }
        for id in Array(metas.keys) {
            guard let m = metas[id], m.status == "downloading" || m.status == "paused" else { continue }
            for idx in m.downloaded where !m.merged.contains(idx) { startMerge(id, idx) }
            ensureTasks(id)
        }
        refreshRows()
    }

    private static func parse(_ desc: String?) -> (String, Int)? {
        guard let d = desc else { return nil }
        let p = d.components(separatedBy: "|")
        guard p.count == 2, let i = Int(p[1]) else { return nil }
        return (p[0], i)
    }

    // MARK: URLSession delegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let (id, idx) = Self.parse(downloadTask.taskDescription) else { return }
        partial[id, default: [:]][idx] = totalBytesWritten
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let desc = downloadTask.taskDescription, let (id, idx) = Self.parse(desc),
              let m = metas[id], m.status == "downloading" || m.status == "paused" else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0

        if [429, 502, 503, 504].contains(status) {
            scheduleRetry(id, desc, reason: "HTTP \(status)")
            return
        }
        if m.ranged {
            let size = (try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
            if status != 206 {
                failItem(id, "The server stopped honoring range requests (HTTP \(status)). Try again later.")
                return
            }
            if Int64(size) != chunkLength(m, idx) {
                scheduleRetry(id, desc, reason: "size mismatch")
                return
            }
        } else if !(200..<300).contains(status) {
            failItem(id, "Server returned HTTP \(status).")
            return
        }

        let dest = partsDir(id).appendingPathComponent(String(idx) + ".part")
        try? FileManager.default.removeItem(at: dest)
        do {
            try FileManager.default.createDirectory(at: partsDir(id), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            failItem(id, "Couldn't store part \(idx + 1): \(error.localizedDescription)")
            return
        }
        if !(metas[id]?.downloaded.contains(idx) ?? true) { metas[id]?.downloaded.append(idx) }
        partial[id]?[idx] = nil
        saveState()
        startMerge(id, idx)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let desc = task.taskDescription, let (id, _) = Self.parse(desc) else { return }
        live[desc] = nil
        guard let error = error else { ensureTasks(id); return }   // a slot freed up: start the next part
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        guard let m = metas[id], m.status == "downloading" || m.status == "paused" else { return }
        scheduleRetry(id, desc, reason: error.localizedDescription)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            self.bgCompletion?()
            self.bgCompletion = nil
        }
    }

    private func scheduleRetry(_ id: String, _ desc: String, reason: String) {
        let n = (retries[desc] ?? 0) + 1
        retries[desc] = n
        if n > 6 {
            failItem(id, "A part kept failing (\(reason)).")
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(min(n, 5)) * 2) { [weak self] in
            self?.opQueue.addOperation { self?.ensureTasks(id) }
        }
    }

    private func failItem(_ id: String, _ msg: String) {
        metas[id]?.status = "failed"
        metas[id]?.error = msg
        for (k, t) in live where k.hasPrefix(id + "|") { t.cancel() }
        saveState()
        toast(msg)
        refreshRows()
    }

    // MARK: Merging (each finished chunk is written straight into its place in the final file)

    private func startMerge(_ id: String, _ idx: Int) {
        guard let m = metas[id] else { return }
        let key = id + "|" + String(idx)
        if merging.contains(key) { return }
        merging.insert(key)
        let part = partsDir(id).appendingPathComponent(String(idx) + ".part")
        let work = workURL(m)
        let offset = UInt64(Int64(idx) * m.chunkSize)
        mergeQueue.async { [weak self] in
            var err: String?
            if FileManager.default.fileExists(atPath: part.path) {
                do {
                    if !FileManager.default.fileExists(atPath: work.path) {
                        FileManager.default.createFile(atPath: work.path, contents: nil)
                    }
                    let out = try FileHandle(forWritingTo: work)
                    let inp = try FileHandle(forReadingFrom: part)
                    defer { try? out.close(); try? inp.close() }
                    try out.seek(toOffset: offset)
                    while true {
                        let data = try autoreleasepool { try inp.read(upToCount: 4 * 1024 * 1024) }
                        guard let d = data, !d.isEmpty else { break }
                        try out.write(contentsOf: d)
                    }
                    try FileManager.default.removeItem(at: part)
                } catch {
                    err = error.localizedDescription
                }
            }
            self?.opQueue.addOperation { self?.mergeFinished(id, idx, err) }
        }
    }

    private func mergeFinished(_ id: String, _ idx: Int, _ err: String?) {
        merging.remove(id + "|" + String(idx))
        guard metas[id] != nil else { return }
        if let err = err {
            failItem(id, "Couldn't write to disk: \(err)")
            return
        }
        if !(metas[id]?.merged.contains(idx) ?? true) { metas[id]?.merged.append(idx) }
        saveState()
        if let m = metas[id], m.status == "downloading", Set(m.merged).count == m.chunkCount {
            finish(id)
        }
    }

    private func finish(_ id: String) {
        guard var m = metas[id] else { return }
        let work = workURL(m)
        let size = (try? work.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if m.total > 0 && Int64(size) != m.total {
            failItem(id, "Final size didn't match (\(size) of \(m.total) bytes). Retry the download.")
            return
        }
        let dest = Self.uniqueURL(for: m.filename)
        do {
            try FileManager.default.moveItem(at: work, to: dest)
        } catch {
            failItem(id, "Couldn't save the file: \(error.localizedDescription)")
            return
        }
        m.status = "done"
        m.finalName = dest.lastPathComponent
        if m.total <= 0 { m.total = Int64(size) }
        metas[id] = m
        try? FileManager.default.removeItem(at: partsDir(id))
        partial[id] = nil
        saveState()
        toast("Finished: \(dest.lastPathComponent)")
        let c = UNMutableNotificationContent()
        c.title = "Download finished"
        c.body = dest.lastPathComponent
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        refreshRows()
    }

    // MARK: Controls

    func pause(_ id: String) {
        opQueue.addOperation { [self] in
            guard metas[id]?.status == "downloading" else { return }
            metas[id]?.status = "paused"
            saveState()
            for (k, t) in live where k.hasPrefix(id + "|") { t.suspend() }
            refreshRows()
        }
    }

    func resumeDownload(_ id: String) {
        opQueue.addOperation { [self] in
            guard let st = metas[id]?.status, st == "paused" || st == "failed" else { return }
            metas[id]?.status = "downloading"
            metas[id]?.error = nil
            retries = retries.filter { !$0.key.hasPrefix(id + "|") }
            saveState()
            for (k, t) in live where k.hasPrefix(id + "|") { t.resume() }
            ensureTasks(id)
            if let m = metas[id] {
                for idx in m.downloaded where !m.merged.contains(idx) { startMerge(id, idx) }
            }
            refreshRows()
        }
    }

    /// Cancels an active download and deletes its temp data. For finished items it only removes the list entry.
    func remove(_ id: String) {
        opQueue.addOperation { [self] in
            for (k, t) in live where k.hasPrefix(id + "|") { t.cancel() }
            if let m = metas[id] { try? FileManager.default.removeItem(at: workURL(m)) }
            try? FileManager.default.removeItem(at: partsDir(id))
            metas[id] = nil
            partial[id] = nil
            lastBytes[id] = nil
            speeds[id] = nil
            saveState()
            refreshRows()
        }
    }

    // MARK: Progress

    private func bytesReceived(_ m: DLMeta) -> Int64 {
        if m.status == "done" { return max(m.total, 0) }
        var s: Int64 = 0
        for i in m.downloaded { s += chunkLength(m, i) }
        for (i, b) in partial[m.id] ?? [:] where !m.downloaded.contains(i) { s += b }
        return s
    }

    private func refreshRows() {
        let now = Date()
        let dt = max(now.timeIntervalSince(lastSample), 0.001)
        lastSample = now
        var out: [DLRow] = []
        for m in metas.values.sorted(by: { $0.addedAt > $1.addedAt }) {
            let done = bytesReceived(m)
            let prev = lastBytes[m.id] ?? done
            let inst = max(0, Double(done - prev) / dt)
            let sp = m.status == "downloading" ? (speeds[m.id] ?? inst) * 0.6 + inst * 0.4 : 0
            speeds[m.id] = sp
            lastBytes[m.id] = done
            let fileURL: URL? = m.status == "done"
                ? Self.docsDir.appendingPathComponent(m.finalName ?? m.filename) : nil
            out.append(DLRow(id: m.id, filename: m.filename, total: m.total, received: done,
                             speed: sp, status: m.status, error: m.error, fileURL: fileURL))
        }
        DispatchQueue.main.async { self.rows = out }
    }

    // MARK: Helpers

    static func freeSpace() -> Int64? {
        let v = try? URL(fileURLWithPath: NSHomeDirectory())
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    static func sanitize(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let c = s.components(separatedBy: bad).joined(separator: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return c.isEmpty ? "download" : c
    }

    static func filename(from http: HTTPURLResponse, url: URL) -> String {
        if let cd = http.value(forHTTPHeaderField: "Content-Disposition") {
            let parts = cd.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            for p in parts where p.lowercased().hasPrefix("filename*=") {
                var v = String(p.dropFirst("filename*=".count))
                if let r = v.range(of: "''") { v = String(v[r.upperBound...]) }
                if let d = v.removingPercentEncoding, !d.isEmpty { return sanitize(d) }
            }
            for p in parts where p.lowercased().hasPrefix("filename=") {
                let v = String(p.dropFirst("filename=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if !v.isEmpty { return sanitize(v) }
            }
        }
        let last = url.lastPathComponent
        if last.isEmpty || last == "/" { return "download" }
        return sanitize(last.removingPercentEncoding ?? last)
    }

    static func uniqueURL(for name: String) -> URL {
        let dir = docsDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var url = dir.appendingPathComponent(sanitize(name))
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return url
    }
}

// MARK: - UI

struct DownloadsView: View {
    @ObservedObject var dl = DownloadManager.shared
    @ObservedObject var m: BrowserModel
    @State private var newURL = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Paste a file URL", text: $newURL)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.default)
                        Button("Add") {
                            let t = newURL.trimmingCharacters(in: .whitespacesAndNewlines)
                            if let u = URL(string: t), u.scheme?.hasPrefix("http") == true {
                                m.startDownload(u)
                                newURL = ""
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                } footer: {
                    Text("Files are saved to Files › On My iPhone › Kitsu › Downloads.")
                }
                if dl.rows.isEmpty {
                    Text("No downloads yet").foregroundColor(.secondary)
                }
                ForEach(dl.rows) { r in DownloadRowView(row: r, dl: dl) }
            }
            .navigationTitle("Downloads")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Open Files") {
                        if let u = URL(string: "shareddocuments://" + DownloadManager.docsDir.path) {
                            UIApplication.shared.open(u)
                        }
                    }
                }
            }
        }
    }
}

struct DownloadRowView: View {
    let row: DLRow
    let dl: DownloadManager

    private func bytes(_ b: Int64) -> String { ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }

    private func eta(_ s: Double) -> String {
        let t = Int(s)
        if t >= 3600 { return "\(t / 3600)h \((t % 3600) / 60)m" }
        if t >= 60 { return "\(t / 60)m \(t % 60)s" }
        return "\(t)s"
    }

    private var detail: String {
        switch row.status {
        case "done": return bytes(row.total) + " · Done"
        case "failed": return row.error ?? "Failed"
        case "paused": return row.total > 0 ? "\(bytes(row.received)) of \(bytes(row.total)) · Paused" : "Paused"
        default:
            var s = row.total > 0 ? "\(bytes(row.received)) of \(bytes(row.total))" : bytes(row.received)
            if row.speed > 1 {
                s += " · \(bytes(Int64(row.speed)))/s"
                if row.total > 0 { s += " · " + eta(Double(row.total - row.received) / row.speed) }
            }
            return s
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(row.filename).lineLimit(2).font(.body)
            if row.status == "downloading" || row.status == "paused" {
                if row.total > 0 {
                    ProgressView(value: Double(min(row.received, row.total)), total: Double(row.total))
                } else {
                    ProgressView()
                }
            }
            Text(detail).font(.caption).foregroundColor(row.status == "failed" ? .red : .secondary)
            HStack(spacing: 20) {
                switch row.status {
                case "downloading":
                    Button { dl.pause(row.id) } label: { Label("Pause", systemImage: "pause.fill") }
                case "paused", "failed":
                    Button { dl.resumeDownload(row.id) } label: {
                        Label(row.status == "failed" ? "Retry" : "Resume", systemImage: "play.fill")
                    }
                default:
                    if let u = row.fileURL { ShareLink(item: u) { Label("Share", systemImage: "square.and.arrow.up") } }
                }
                Button(role: .destructive) { dl.remove(row.id) } label: {
                    Label(row.status == "done" ? "Remove" : "Cancel", systemImage: "xmark")
                }
            }
            .font(.footnote)
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 4)
    }
}
