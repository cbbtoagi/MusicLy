import AppKit
import CoreGraphics
import Foundation
#if ENABLE_OCR
import Vision
#endif

// MARK: - Data Models

struct PlaybackState: Equatable {
    var title: String
    var artist: String
    var album: String
    var position: Double
    var duration: Double
    var isPlaying: Bool
    var isRunning: Bool

    static let empty = PlaybackState(
        title: "", artist: "", album: "", position: 0, duration: 0,
        isPlaying: false, isRunning: false
    )

    var trackKey: String { "\(title)\u{1}\(artist)\u{1}\(album)" }
}

struct LyricLine: Equatable {
    var time: Double          // seconds from start
    var text: String
    var translation: String?
}

struct SyncedLyrics: Equatable {
    var lines: [LyricLine]    // sorted ascending by time
    var source: String
    var hasTimes: Bool

    func withSource(_ s: String) -> SyncedLyrics {
        SyncedLyrics(lines: lines, source: s, hasTimes: hasTimes)
    }

    /// Index of the last line whose time <= position. Returns nil if position
    /// precedes the first line (intro) or there are no synced lines.
    func index(at position: Double) -> Int? {
        guard hasTimes, !lines.isEmpty else { return nil }
        var lo = 0, hi = lines.count - 1, res = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= position { res = mid; lo = mid + 1 }
            else { hi = mid - 1 }
        }
        return res >= 0 ? res : nil
    }
}

#if ENABLE_OCR
// Display snapshot used by the OCR fallback path.
struct LyricDisplay: Equatable {
    var currentLine: String
    var translation: String?
    var previousLine: String?
    var nextLine: String?
    var source: String
    var debugInfo: String
    var isAvailable: Bool

    static let empty = LyricDisplay(
        currentLine: "", translation: nil, previousLine: nil, nextLine: nil,
        source: "Unavailable", debugInfo: "", isAvailable: false
    )
}
#endif

// MARK: - Playback Reader (Apple Events — works whether window is visible, hidden, or minimized)

final class PlaybackReader: @unchecked Sendable {
    func readState() -> PlaybackState {
        let script = #"""
        if application "Music" is running then
            tell application "Music"
                if not (exists current track) then return "RUNNING||||0|0|STOPPED"
                set n to name of current track
                set a to artist of current track
                set al to album of current track
                set d to duration of current track
                set p to player position
                set s to player state as text
                return "RUNNING|" & n & "|" & a & "|" & al & "|" & (p as text) & "|" & (d as text) & "|" & s
            end tell
        else
            return "NOT_RUNNING"
        end if
        """#
        guard let as_ = NSAppleScript(source: script) else { return .empty }
        var err: NSDictionary?
        let out = as_.executeAndReturnError(&err).stringValue ?? ""
        if err != nil || out == "NOT_RUNNING" { return .empty }
        let p = out.components(separatedBy: "|")
        guard p.count >= 7 else {
            return PlaybackState(title: "", artist: "", album: "", position: 0, duration: 0, isPlaying: false, isRunning: true)
        }
        let playing = p[6].lowercased().contains("playing")
        return PlaybackState(
            title: p[1], artist: p[2], album: p[3],
            position: Double(p[4].replacingOccurrences(of: ",", with: ".")) ?? 0,
            duration: Double(p[5].replacingOccurrences(of: ",", with: ".")) ?? 0,
            isPlaying: playing, isRunning: true
        )
    }
}

// MARK: - LRC Parser

enum LRCParser {
    static func parse(_ raw: String) -> SyncedLyrics? {
        var offset = 0.0
        var out: [LyricLine] = []

        for rawLine in raw.components(separatedBy: .newlines) {
            var s = Substring(rawLine)
            var times: [Double] = []

            // Consume leading bracket groups: timestamps and/or metadata tags.
            while s.first == "[", let close = s.firstIndex(of: "]") {
                let inner = s[s.index(after: s.startIndex)..<close]
                s = s[s.index(after: close)...]
                if let t = parseTime(inner) {
                    times.append(t)
                } else {
                    let low = inner.lowercased()
                    if low.hasPrefix("offset:") {
                        let v = inner.dropFirst("offset:".count).trimmingCharacters(in: .whitespaces)
                        offset = (Double(v) ?? 0) / 1000.0
                    }
                    // other metadata tags ([ar:][ti:][al:][by:][length:]) are ignored
                }
            }

            guard !times.isEmpty else { continue }
            let text = String(s).trimmingCharacters(in: .whitespacesAndNewlines)
            for t in times {
                out.append(LyricLine(time: t, text: text, translation: nil))
            }
        }

        guard !out.isEmpty else { return nil }
        out.sort { $0.time < $1.time }

        // LRC offset convention: positive value means lyrics should appear earlier.
        if offset != 0 {
            out = out.map { LyricLine(time: max(0, $0.time - offset), text: $0.text, translation: $0.translation) }
        }

        out = mergeBilingual(out)
        return SyncedLyrics(lines: out, source: "LRC", hasTimes: true)
    }

    private static func parseTime(_ s: Substring) -> Double? {
        let comps = s.split(separator: ":").map(String.init)
        func d(_ x: String) -> Double? { Double(x.replacingOccurrences(of: ",", with: ".")) }
        if comps.count == 2 {
            guard let m = d(comps[0]), let sec = d(comps[1]) else { return nil }
            return m * 60 + sec
        } else if comps.count == 3 {
            guard let h = d(comps[0]), let m = d(comps[1]), let sec = d(comps[2]) else { return nil }
            return h * 3600 + m * 60 + sec
        }
        return nil
    }

    // Many Chinese sources emit original + translation as two lines sharing a timestamp.
    private static func mergeBilingual(_ lines: [LyricLine]) -> [LyricLine] {
        var result: [LyricLine] = []
        var i = 0
        while i < lines.count {
            let cur = lines[i]
            if i + 1 < lines.count,
               abs(lines[i + 1].time - cur.time) < 0.05,
               !lines[i + 1].text.isEmpty, !cur.text.isEmpty,
               lines[i + 1].text != cur.text {
                var merged = cur
                merged.translation = lines[i + 1].text
                result.append(merged)
                i += 2
            } else {
                result.append(cur)
                i += 1
            }
        }
        return result
    }
}

// MARK: - Lyrics Provider (local file → disk cache → LRCLIB; free, no API key)

final class LyricsProvider: @unchecked Sendable {
    private let cacheDir: URL
    private let localDir: URL
    private let session: URLSession
    private let noneMarker = "\u{0}MUSICLY_NONE"

    init() {
        let fm = FileManager.default
        let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        cacheDir = caches.appendingPathComponent("local.musicly.app/lyrics", isDirectory: true)
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? caches
        localDir = support.appendingPathComponent("MusicLy/Lyrics", isDirectory: true)
        try? fm.createDirectory(at: localDir, withIntermediateDirectories: true)

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 8
        cfg.timeoutIntervalForResource = 12
        cfg.waitsForConnectivity = false
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    func fetch(title: String, artist: String, album: String, duration: Double, force: Bool) async -> SyncedLyrics? {
        // 1. User-authored local LRC always wins.
        if let local = loadLocal(title: title, artist: artist) { return local }

        let cacheFile = cacheDir.appendingPathComponent(cacheKey(title: title, artist: artist, duration: duration) + ".lrc")

        // 2. Disk cache (unless forced reload).
        if !force, let cached = try? String(contentsOf: cacheFile, encoding: .utf8), !cached.isEmpty {
            if cached == noneMarker { return nil }
            if let parsed = LRCParser.parse(cached) { return parsed.withSource("Cache") }
        }

        // 3. Network (LRCLIB — free, no key, read-only).
        switch await fetchNetwork(title: title, artist: artist, album: album, duration: duration) {
        case .found(let lrc):
            try? lrc.write(to: cacheFile, atomically: true, encoding: .utf8)
            if let parsed = LRCParser.parse(lrc) { return parsed.withSource("LRCLIB") }
            return nil
        case .notFound:
            try? noneMarker.write(to: cacheFile, atomically: true, encoding: .utf8)
            return nil
        case .error:
            // Transient — do not poison the cache; allow a retry on the next play.
            return nil
        }
    }

    private enum NetResult { case found(String), notFound, error }

    private func fetchNetwork(title: String, artist: String, album: String, duration: Double) async -> NetResult {
        guard !title.isEmpty else { return .notFound }
        var sawNotFound = false

        // Exact match endpoint (matches on duration ±2s when provided).
        if var comps = URLComponents(string: "https://lrclib.net/api/get") {
            comps.queryItems = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist),
            ]
            if !album.isEmpty { comps.queryItems?.append(URLQueryItem(name: "album_name", value: album)) }
            if duration > 1 { comps.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
            if let url = comps.url {
                let (data, code) = await request(url)
                if code == 404 { sawNotFound = true }
                if let data, let resp = try? JSONDecoder().decode(LRCLIBResponse.self, from: data) {
                    if let s = resp.syncedLyrics, !s.isEmpty { return .found(s) }
                    if resp.instrumental == true { return .notFound }
                }
            }
        }

        // Fuzzy search fallback (no duration constraint).
        if var comps = URLComponents(string: "https://lrclib.net/api/search") {
            comps.queryItems = [
                URLQueryItem(name: "track_name", value: title),
                URLQueryItem(name: "artist_name", value: artist),
            ]
            if let url = comps.url {
                let (data, _) = await request(url)
                if let data, let arr = try? JSONDecoder().decode([LRCLIBResponse].self, from: data) {
                    if let hit = arr.first(where: { ($0.syncedLyrics?.isEmpty == false) }), let s = hit.syncedLyrics {
                        return .found(s)
                    }
                    if !arr.isEmpty { sawNotFound = true }
                }
            }
        }

        return sawNotFound ? .notFound : .error
    }

    private func request(_ url: URL) async -> (Data?, Int) {
        var req = URLRequest(url: url)
        req.setValue("MusicLy/1.0 (macOS menu bar lyrics; personal use)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (code == 200 ? data : nil, code)
        } catch {
            return (nil, -1)
        }
    }

    private func loadLocal(title: String, artist: String) -> SyncedLyrics? {
        let candidates = ["\(artist) - \(title)", "\(title) - \(artist)", title]
        for name in candidates {
            let file = localDir.appendingPathComponent(sanitizeFilename(name) + ".lrc")
            if let s = try? String(contentsOf: file, encoding: .utf8), let parsed = LRCParser.parse(s) {
                return parsed.withSource("Local")
            }
        }
        return nil
    }

    private func sanitizeFilename(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return String(s.unicodeScalars.map { bad.contains($0) ? "_" : Character($0) })
    }

    private func cacheKey(title: String, artist: String, duration: Double) -> String {
        let base = "\(artist)|\(title)|\(Int(duration.rounded()))"
        var hash: UInt64 = 5381
        for b in base.utf8 { hash = (hash &* 33) ^ UInt64(b) }
        return String(format: "%016llx", hash)
    }
}

struct LRCLIBResponse: Decodable {
    let syncedLyrics: String?
    let plainLyrics: String?
    let instrumental: Bool?
}

#if ENABLE_OCR
// MARK: - Lyrics Reader (OCR fallback — only when synced lyrics are unavailable AND window is visible)

final class LyricsOCRReader: @unchecked Sendable {
    private let noLyricsMarkers = [
        "no lyrics available", "no lyrics", "lyrics unavailable",
        "没有可用的歌词", "暂无歌词", "无可用歌词"
    ]

    func readLyrics(playback: PlaybackState) -> LyricDisplay {
        guard playback.isRunning else {
            return LyricDisplay(currentLine: "", translation: nil, previousLine: nil, nextLine: nil, source: "Not running", debugInfo: "Music not running", isAvailable: false)
        }
        guard let windowBounds = findMusicWindow() else {
            return LyricDisplay(currentLine: "", translation: nil, previousLine: nil, nextLine: nil, source: "No window", debugInfo: "Music window not found", isAvailable: false)
        }

        let lyricRegion = estimateLyricRegion(from: windowBounds)
        guard let image = CGWindowListCreateImage(lyricRegion, .optionOnScreenOnly, kCGNullWindowID, [.boundsIgnoreFraming, .bestResolution]) else {
            return LyricDisplay(currentLine: "", translation: nil, previousLine: nil, nextLine: nil, source: "Capture failed", debugInfo: "Screen capture returned nil", isAvailable: false)
        }
        guard image.width > 50, image.height > 50 else {
            return LyricDisplay(currentLine: "", translation: nil, previousLine: nil, nextLine: nil, source: "Region too small", debugInfo: "Capture: \(image.width)x\(image.height)", isAvailable: false)
        }

        let lines = recognizeText(in: image)
        let filtered = filterLyricLines(lines, playback: playback)
        if filtered.isEmpty {
            return LyricDisplay(currentLine: "", translation: nil, previousLine: nil, nextLine: nil, source: "OCR empty", debugInfo: "raw=\(lines.count) filtered=0", isAvailable: false)
        }
        if let marker = filtered.first(where: { l in noLyricsMarkers.contains(where: { l.text.lowercased().contains($0) }) }) {
            return LyricDisplay(currentLine: "", translation: nil, previousLine: nil, nextLine: nil, source: "No lyrics for track", debugInfo: "marker: \(marker.text)", isAvailable: false)
        }

        let selected = selectHighlightedLine(from: filtered)
        let idx = selected.index
        let current = filtered[idx]
        let prev = idx > 0 ? filtered[idx - 1].text : nil
        let next = idx + 1 < filtered.count ? filtered[idx + 1].text : nil

        return LyricDisplay(
            currentLine: current.text, translation: nil, previousLine: prev, nextLine: next,
            source: "OCR",
            debugInfo: "raw=\(lines.count) filtered=\(filtered.count) idx=\(idx)",
            isAvailable: true
        )
    }

    private func findMusicWindow() -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var best: CGRect?
        var bestArea: CGFloat = 0
        for info in list {
            guard let owner = info[kCGWindowOwnerName as String] as? String, owner == "Music" else { continue }
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            guard rect.width > 500, rect.height > 300 else { continue }
            let area = rect.width * rect.height
            if area > bestArea { bestArea = area; best = rect }
        }
        return best
    }

    private func estimateLyricRegion(from window: CGRect) -> CGRect {
        CGRect(
            x: window.minX + window.width * 0.58,
            y: window.minY + window.height * 0.13,
            width: window.width * 0.38,
            height: window.height * 0.74
        ).integral
    }

    private func recognizeText(in image: CGImage) -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.015
        request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant", "ja-JP", "ko-KR"]
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        guard let results = request.results else { return [] }
        return results.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return RecognizedLine(text: candidate.string, rect: obs.boundingBox, confidence: candidate.confidence)
        }.sorted { $0.rect.midY > $1.rect.midY }
    }

    private func filterLyricLines(_ lines: [RecognizedLine], playback: PlaybackState) -> [RecognizedLine] {
        lines.filter { line in
            let t = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 2, line.confidence >= 0.4 else { return false }
            let lower = t.lowercased()
            let blocked = ["资料库", "搜索", "browse", "radio", "listen now", "apple music",
                          "autoplay", "up next", "shuffle", "repeat", "playlist", "station",
                          "button", "controls", "volume", "airplay", "karaoke", "歌词显示",
                          "auto-close", "pinned", "musicly", "window frame", "screen recording"]
            if blocked.contains(where: { lower.contains($0) }) { return false }
            if !playback.title.isEmpty && lower == playback.title.lowercased() { return false }
            if !playback.artist.isEmpty && lower == playback.artist.lowercased() { return false }
            return true
        }
    }

    private func selectHighlightedLine(from lines: [RecognizedLine]) -> (index: Int, line: RecognizedLine) {
        guard !lines.isEmpty else { return (0, lines.first!) }
        var bestIdx = 0
        var bestScore: Float = -1
        for (i, line) in lines.enumerated() {
            let centerDist = abs(line.rect.midY - 0.50)
            let centerScore = Float(max(0, 1.0 - centerDist * 2.5))
            let confScore = line.confidence
            let widthScore = Float(min(line.rect.width * 1.5, 0.6))
            let score = centerScore + confScore * 0.5 + widthScore
            if score > bestScore { bestScore = score; bestIdx = i }
        }
        return (bestIdx, lines[bestIdx])
    }
}

struct RecognizedLine {
    let text: String
    let rect: CGRect
    let confidence: Float
}

// MARK: - OCR Tracker (smooths the fallback OCR path across frames)

final class OCRTracker {
    private var lastTrackKey = ""
    private var lastDisplay = LyricDisplay.empty
    private var lastUpdate = Date()
    private var staleSeconds = 0.0

    func update(playback: PlaybackState, ocrResult: LyricDisplay) -> LyricDisplay {
        if playback.trackKey != lastTrackKey {
            lastTrackKey = playback.trackKey
            lastDisplay = ocrResult
            lastUpdate = Date()
            staleSeconds = 0
            return ocrResult
        }
        if ocrResult.isAvailable {
            if ocrResult.currentLine != lastDisplay.currentLine {
                staleSeconds = 0
                lastDisplay = ocrResult
                lastUpdate = Date()
                return ocrResult
            }
            if playback.isPlaying { staleSeconds += Date().timeIntervalSince(lastUpdate) }
            lastUpdate = Date()
            lastDisplay = ocrResult
            return ocrResult
        } else {
            if lastDisplay.isAvailable && staleSeconds < 3.0 {
                if playback.isPlaying { staleSeconds += Date().timeIntervalSince(lastUpdate) }
                lastUpdate = Date()
                return lastDisplay
            }
            lastUpdate = Date()
            return ocrResult
        }
    }

    func reset() { lastTrackKey = ""; lastDisplay = .empty; staleSeconds = 0; lastUpdate = Date() }
}
#endif

// MARK: - Hover View

final class HoverClosingView: NSView {
    var onMouseExit: (() -> Void)?
    var onMouseEnter: (() -> Void)?
    private var trackingAreaRef: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef { removeTrackingArea(trackingAreaRef) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingAreaRef = area
    }
    override func mouseEntered(with event: NSEvent) { super.mouseEntered(with: event); onMouseEnter?() }
    override func mouseExited(with event: NSEvent) { super.mouseExited(with: event); onMouseExit?() }
}

// MARK: - App Controller

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: 300)
    private let popover = NSPopover()
    private let playbackReader = PlaybackReader()
    private let provider = LyricsProvider()
    #if ENABLE_OCR
    private let ocrReader = LyricsOCRReader()
    private let ocrTracker = OCRTracker()
    private var lastOCR: LyricDisplay?
    #endif
    private let workerQueue = DispatchQueue(label: "local.musicly.worker", qos: .userInitiated)

    private var pollTimer: Timer?
    private var renderTimer: Timer?
    private var isPolling = false

    // Playback sampling + interpolation
    private var playback = PlaybackState.empty
    private var sampledPosition = 0.0
    private var sampledAt = Date()

    // Synced-lyrics state
    private var currentTrackKey = ""
    private var currentLyrics: SyncedLyrics?
    private var currentLineIndex = Int.min
    private var globalOffset = 0.0

    // Display snapshot
    private var dispCurrent = ""
    private var dispTranslation: String?
    private var dispPrev: String?
    private var dispNext: String?
    private var dispSource = "Starting"

    private var hoverCloseWorkItem: DispatchWorkItem?
    private var lastRenderSig = ""
    private var isPopoverPinned = false

    private let currentLabel = NSTextField(labelWithString: "Starting MusicLy...")
    private let translationLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        setupPopover()

        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(musicChanged),
            name: NSNotification.Name("com.apple.Music.playerInfo"), object: nil
        )

        poll()
        // Heavy poll: Apple Events (+ OCR fallback) every 0.5s — re-anchors position and detects track/seek.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        // Light tick: pure local interpolation @ 10 fps — keeps the displayed line in real-time sync.
        renderTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        if let pollTimer { RunLoop.main.add(pollTimer, forMode: .common) }
        if let renderTimer { RunLoop.main.add(renderTimer, forMode: .common) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        renderTimer?.invalidate()
    }

    @objc private func musicChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.poll() }
    }

    // MARK: Status item & popover

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }
        button.title = "MusicLy"
        button.target = self
        button.action = #selector(handleClick)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.lineBreakMode = .byTruncatingTail
    }

    private func setupPopover() {
        let view = HoverClosingView(frame: NSRect(x: 0, y: 0, width: 520, height: 270))
        view.onMouseEnter = { [weak self] in self?.hoverCloseWorkItem?.cancel() }
        view.onMouseExit = { [weak self] in self?.scheduleClose() }

        currentLabel.font = .systemFont(ofSize: 21, weight: .semibold)
        currentLabel.maximumNumberOfLines = 2; currentLabel.lineBreakMode = .byWordWrapping
        currentLabel.frame = NSRect(x: 18, y: 192, width: 484, height: 56)

        translationLabel.font = .systemFont(ofSize: 15, weight: .regular)
        translationLabel.textColor = .secondaryLabelColor
        translationLabel.maximumNumberOfLines = 2; translationLabel.lineBreakMode = .byWordWrapping
        translationLabel.frame = NSRect(x: 18, y: 150, width: 484, height: 38)

        contextLabel.font = .systemFont(ofSize: 14, weight: .regular)
        contextLabel.textColor = .tertiaryLabelColor
        contextLabel.maximumNumberOfLines = 4; contextLabel.lineBreakMode = .byWordWrapping
        contextLabel.frame = NSRect(x: 18, y: 70, width: 484, height: 72)

        detailLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        detailLabel.textColor = .quaternaryLabelColor
        detailLabel.maximumNumberOfLines = 3; detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: 18, y: 12, width: 484, height: 48)

        view.addSubview(currentLabel); view.addSubview(translationLabel)
        view.addSubview(contextLabel); view.addSubview(detailLabel)

        let vc = NSViewController(); vc.view = view
        popover.contentSize = view.frame.size
        popover.behavior = .applicationDefined
        popover.contentViewController = vc
    }

    @objc private func handleClick() {
        guard let event = NSApp.currentEvent else { togglePopover(); return }
        if event.type == .rightMouseUp { showMenu() } else { togglePopover() }
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: isPopoverPinned ? "Unpin Panel" : "Pin Panel", action: #selector(togglePin), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Sync Earlier (−0.2s)", action: #selector(syncEarlier), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Sync Later (+0.2s)", action: #selector(syncLater), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reset Sync Offset", action: #selector(resetOffset), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Reload Lyrics", action: #selector(reloadLyrics), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MusicLy", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu; statusItem.button?.performClick(nil); statusItem.menu = nil
    }

    private func togglePopover() {
        guard let button = statusItem.button else { return }
        hoverCloseWorkItem?.cancel()
        if popover.isShown { popover.performClose(nil) }
        else { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    private func scheduleClose() {
        guard !isPopoverPinned else { return }
        hoverCloseWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.popover.isShown else { return }
            self.popover.performClose(nil)
        }
        hoverCloseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    @objc private func togglePin() { isPopoverPinned.toggle(); if !isPopoverPinned { scheduleClose() } }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func syncEarlier() { globalOffset -= 0.2; forceResync() }
    @objc private func syncLater() { globalOffset += 0.2; forceResync() }
    @objc private func resetOffset() { globalOffset = 0; forceResync() }
    @objc private func reloadLyrics() {
        #if ENABLE_OCR
        ocrTracker.reset()
        #endif
        currentLyrics = nil
        currentLineIndex = Int.min
        if !playback.title.isEmpty { fetchLyrics(for: playback, force: true) }
    }

    private func forceResync() {
        currentLineIndex = Int.min
        tick()
        render()
    }

    // MARK: Polling & interpolation

    private func estimatedPosition() -> Double {
        guard playback.isPlaying else { return sampledPosition }
        return sampledPosition + Date().timeIntervalSince(sampledAt)
    }

    private func poll() {
        guard !isPolling else { return }
        isPolling = true
        let reader = playbackReader
        #if ENABLE_OCR
        let needOCR = (currentLyrics == nil)
        let ocr = ocrReader
        #endif
        workerQueue.async { [weak self] in
            let state = reader.readState()
            #if ENABLE_OCR
            var ocrResult: LyricDisplay?
            if needOCR && state.isRunning && state.isPlaying {
                ocrResult = ocr.readLyrics(playback: state)
            }
            #endif
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                #if ENABLE_OCR
                self.lastOCR = ocrResult
                #endif
                self.applyPoll(state: state)
                self.isPolling = false
            }
        }
    }

    private func applyPoll(state: PlaybackState) {
        if state.trackKey != currentTrackKey {
            currentTrackKey = state.trackKey
            currentLyrics = nil
            currentLineIndex = Int.min
            #if ENABLE_OCR
            ocrTracker.reset()
            #endif
            dispTranslation = nil; dispPrev = nil; dispNext = nil
            if !state.title.isEmpty { fetchLyrics(for: state, force: false) }
        }

        playback = state
        sampledPosition = state.position
        sampledAt = Date()

        // When we have synced lyrics, tick() drives the display. Otherwise render here.
        guard currentLyrics == nil else { return }

        #if ENABLE_OCR
        if let ocr = lastOCR {
            let tracked = ocrTracker.update(playback: state, ocrResult: ocr)
            if tracked.isAvailable {
                dispCurrent = tracked.currentLine
                dispTranslation = tracked.translation
                dispPrev = tracked.previousLine
                dispNext = tracked.nextLine
                dispSource = "OCR"
            } else {
                setFallbackDisplay(state, source: tracked.source)
            }
            render()
            return
        }
        #endif

        setFallbackDisplay(state, source: state.isRunning ? (state.title.isEmpty ? "Idle" : "Loading") : "Idle")
        render()
    }

    private func tick() {
        guard let lyrics = currentLyrics, lyrics.hasTimes, !lyrics.lines.isEmpty else { return }
        let pos = estimatedPosition() + globalOffset
        let idx = lyrics.index(at: pos) ?? -1
        if idx != currentLineIndex {
            currentLineIndex = idx
            updateDisplayFromSynced(lyrics)
            render()
        }
    }

    private func updateDisplayFromSynced(_ lyrics: SyncedLyrics) {
        if currentLineIndex < 0 {
            dispCurrent = ""
            dispTranslation = nil
            dispPrev = nil
            dispNext = lyrics.lines.first?.text
        } else {
            let line = lyrics.lines[currentLineIndex]
            dispCurrent = line.text
            dispTranslation = line.translation
            dispPrev = currentLineIndex > 0 ? lyrics.lines[currentLineIndex - 1].text : nil
            dispNext = currentLineIndex + 1 < lyrics.lines.count ? lyrics.lines[currentLineIndex + 1].text : nil
        }
        dispSource = lyrics.source
    }

    private func setFallbackDisplay(_ state: PlaybackState, source: String) {
        dispCurrent = ""
        dispTranslation = nil
        dispPrev = nil
        dispNext = nil
        dispSource = source
    }

    private func fetchLyrics(for state: PlaybackState, force: Bool) {
        let key = state.trackKey
        let provider = self.provider
        Task.detached(priority: .userInitiated) {
            let lyrics = await provider.fetch(
                title: state.title, artist: state.artist, album: state.album,
                duration: state.duration, force: force
            )
            await MainActor.run { [weak self] in
                guard let self, self.currentTrackKey == key else { return }
                self.currentLyrics = lyrics
                self.currentLineIndex = Int.min
                if lyrics == nil {
                    // No synced lyrics — next poll's OCR fallback (if visible) takes over.
                    self.setFallbackDisplay(self.playback, source: "No synced lyrics")
                    self.render()
                } else {
                    self.tick()
                }
            }
        }
    }

    // MARK: Rendering

    private func render() {
        let menuText: String
        if !dispCurrent.isEmpty {
            menuText = dispCurrent
        } else if playback.isRunning && !playback.title.isEmpty {
            menuText = playback.isPlaying ? "\u{266A} \(playback.title)" : "\u{275A}\u{275A} \(playback.title)"
        } else {
            menuText = "MusicLy"
        }

        let sig = "\(menuText)|\(dispTranslation ?? "")|\(dispPrev ?? "")|\(dispNext ?? "")|\(dispSource)|\(isPopoverPinned)|\(globalOffset)"
        if sig == lastRenderSig { return }
        lastRenderSig = sig

        statusItem.button?.title = menuText.count > 40 ? String(menuText.prefix(39)) + "\u{2026}" : menuText

        currentLabel.stringValue = !dispCurrent.isEmpty ? dispCurrent : fallbackText()
        translationLabel.stringValue = dispTranslation ?? ""

        var ctx: [String] = []
        if let p = dispPrev, !p.isEmpty { ctx.append("\u{2191} \(p)") }
        if let n = dispNext, !n.isEmpty { ctx.append("\u{2193} \(n)") }
        contextLabel.stringValue = ctx.joined(separator: "\n")

        let st = playback.isRunning
            ? "\(playback.isPlaying ? "\u{25B6}" : "\u{275A}\u{275A}") \(playback.title) \u{2014} \(playback.artist)"
            : "Apple Music not running"
        let offsetStr = globalOffset == 0 ? "" : String(format: " \u{2022} offset %+.1fs", globalOffset)
        detailLabel.stringValue = "\(st)\n\(dispSource) \u{2022} \(isPopoverPinned ? "Pinned" : "Auto-close")\(offsetStr)"
    }

    private func fallbackText() -> String {
        if !playback.isRunning { return "Open Apple Music to start." }
        if playback.title.isEmpty { return "Play a song to see lyrics." }
        return "\u{266A} \(playback.title) \u{2014} \(playback.artist)"
    }
}

// MARK: - Entry Point

@main
struct MusicLyApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppController()
        app.delegate = delegate
        app.run()
    }
}
