import AppKit
import AVFoundation
import CoreMedia
import Network
import SwiftUI

/// Shows the paired phone's screen live on this Mac.
///
/// Uses scrcpy's phone-side server in raw-stream mode: we push it over adb, start
/// it with `app_process`, forward its socket to a local port, and read plain
/// H.264 (Annex B) — no scrcpy window, no extra headers. Frames are decoded in
/// hardware by an `AVSampleBufferDisplayLayer`. Runs alongside critique
/// recordings: each scrcpy session has its own id (`scid`).
@MainActor
final class PhoneMirror: ObservableObject {
    static let shared = PhoneMirror()

    enum State: Equatable {
        case off
        case starting
        case live
        case failed(String)
    }

    @Published private(set) var state: State = .off
    /// The phone's screen size in pixels, once the first frame arrives (portrait or landscape).
    @Published private(set) var videoSize: CGSize?
    /// Where the picture is shown: the Mobile page, or its own full-screen window.
    @Published var placement: Placement = .inline

    enum Placement { case inline, window }

    /// The one view that draws the stream; moved between the page and the window.
    let display = MirrorDisplayView()

    private(set) var serial: String?
    private var server: LineProcess?
    private var stream: MirrorStream?
    private var port: UInt16 = 0
    private var serverLog: [String] = []
    private var window: NSWindow?
    private var windowDelegate: WindowDelegate?

    var isOn: Bool { state == .starting || state == .live }

    // MARK: Turning it on and off

    func start(_ device: ADB.Device) {
        guard !isOn else { return }
        guard let adb = ADB.adbPath else { state = .failed("No adb found."); return }
        guard let jar = Self.serverJar else {
            state = .failed("Install scrcpy to show your phone's screen: brew install scrcpy")
            return
        }
        state = .starting
        videoSize = nil
        serverLog = []
        serial = device.serial
        let serial = device.serial
        let scid = String(format: "%08x", UInt32.random(in: 1...0x7fff_ffff))
        Task {
            guard let version = await Self.scrcpyVersion() else {
                return fail("Couldn't read the scrcpy version. Reinstall it: brew reinstall scrcpy")
            }
            // 1. the server, on the phone
            let push = await ADB.adb(["-s", serial, "push", jar, Self.remoteJar], timeout: 30)
            guard push.ok else { return fail("Couldn't copy the mirror to your phone: \(push.message)") }
            // 2. its socket, on a local port
            let forward = await ADB.adb(["-s", serial, "forward", "tcp:0", "localabstract:scrcpy_\(scid)"])
            guard forward.ok, let port = UInt16(forward.output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return fail("Couldn't reach your phone: \(forward.message)")
            }
            self.port = port
            guard state == .starting else { return cleanUp() }   // turned off meanwhile
            // 3. start it: raw H.264, video only, no input
            let process = LineProcess(adb, ["-s", serial, "shell",
                "CLASSPATH=\(Self.remoteJar)", "app_process", "/", "com.genymobile.scrcpy.Server", version,
                "scid=\(scid)", "log_level=info", "tunnel_forward=true", "audio=false", "control=false",
                "raw_stream=true", "video_codec=h264", "max_size=1600", "video_bit_rate=8000000",
                "max_fps=60", "stay_awake=false", "cleanup=true"]) { [weak self] line in
                self?.serverLog.append(line)
                log("mirror: \(line)")
            }
            process.onExit = { [weak self] _ in self?.serverExited() }
            do { try process.start() } catch { return fail("Couldn't start the mirror: \(error.localizedDescription)") }
            server = process
            // 4. connect once the server is listening
            connect(port: port, attempt: 0)
        }
    }

    func stop() {
        guard state != .off else { return }
        state = .off
        closeWindow()
        cleanUp()
    }

    func toggle(_ device: ADB.Device?) {
        if isOn { stop() } else if let device { start(device) }
    }

    private func fail(_ message: String) {
        log("mirror failed: \(message)")
        state = .failed(message)
        closeWindow()
        cleanUp()
    }

    private func cleanUp() {
        stream?.cancel()
        stream = nil
        server?.stop()
        server = nil
        display.reset()
        if let serial, port != 0 {
            let port = port
            Task { _ = await ADB.adb(["-s", serial, "forward", "--remove", "tcp:\(port)"]) }
        }
        port = 0
    }

    private func serverExited() {
        guard isOn else { return }
        let why = serverLog.last { $0.contains("ERROR") || $0.contains("Exception") }
        fail(why.map { "The mirror stopped: \($0)" } ?? "The mirror stopped. Is the phone still connected?")
    }

    private func connect(port: UInt16, attempt: Int) {
        guard state == .starting else { return }
        let stream = MirrorStream(port: port, display: display) { [weak self] event in
            guard let self else { return }
            switch event {
            case .firstFrame(let size):
                self.videoSize = size
                if self.state == .starting { self.state = .live }
            case .resized(let size):
                self.videoSize = size
            case .closed(let gotData):
                guard self.isOn else { return }
                if !gotData, attempt < 25 {
                    // the server isn't listening yet; try again shortly
                    Task {
                        try? await Task.sleep(for: .milliseconds(200))
                        self.connect(port: port, attempt: attempt + 1)
                    }
                } else {
                    self.fail(gotData ? "Your phone stopped sending its screen." : "Couldn't connect to your phone's screen.")
                }
            }
        }
        self.stream = stream
        stream.start()
    }

    // MARK: Full screen

    /// Opens the stream in its own window and makes it full screen.
    func openFullScreen() {
        guard isOn else { return }
        if let window {
            window.makeKeyAndOrderFront(nil)
            if !window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            return
        }
        placement = .window
        let size = videoSize ?? CGSize(width: 1080, height: 2340)
        let height: CGFloat = 820
        let width = max(320, height * size.width / max(size.height, 1))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Phone screen"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.collectionBehavior = [.fullScreenPrimary]
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MirrorWindowContent())
        let delegate = WindowDelegate { [weak self] in
            self?.window = nil
            self?.windowDelegate = nil
            self?.placement = .inline
        }
        window.delegate = delegate
        windowDelegate = delegate
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { window.toggleFullScreen(nil) }
    }

    private func closeWindow() {
        guard let window else { placement = .inline; return }
        self.window = nil
        windowDelegate = nil
        window.delegate = nil
        if window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
        window.close()
        placement = .inline
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        let onClose: @MainActor () -> Void
        init(onClose: @escaping @MainActor () -> Void) { self.onClose = onClose }
        func windowWillClose(_ notification: Notification) {
            // AppKit calls window delegates on the main thread.
            MainActor.assumeIsolated { onClose() }
        }
    }

    // MARK: scrcpy

    static let remoteJar = "/data/local/tmp/critique-mirror.jar"

    /// scrcpy-server from Homebrew (it's installed alongside the scrcpy binary).
    static var serverJar: String? {
        ["/opt/homebrew/share/scrcpy/scrcpy-server", "/usr/local/share/scrcpy/scrcpy-server"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// The server only accepts a client of its own version: "scrcpy 5.0.1 <…>" → "5.0.1".
    static func scrcpyVersion() async -> String? {
        guard let scrcpy = ADB.scrcpyPath else { return nil }
        let result = await ADB.run(scrcpy, ["--version"], timeout: 10)
        let first = result.output.split(separator: "\n").first ?? ""
        let parts = first.split(separator: " ")
        return parts.count >= 2 && parts[0] == "scrcpy" ? String(parts[1]) : nil
    }
}

// MARK: - The stream: socket → H.264 frames → display

/// Reads raw H.264 from the forwarded socket, splits it into frames, and hands
/// them to the display layer. Lives on its own queue.
/// Unchecked: every mutable field is only touched on `queue`, where the connection's
/// callbacks run (cancel() hops there too).
final class MirrorStream: @unchecked Sendable {
    enum Event {
        case firstFrame(CGSize)
        case resized(CGSize)
        case closed(gotData: Bool)
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.critique.mirror")
    private let display: MirrorDisplayView
    private let onEvent: @MainActor @Sendable (Event) -> Void
    private var buffer = Data()
    private var gotData = false
    private var cancelled = false

    // H.264 state
    private var sps: Data?
    private var pps: Data?
    private var format: CMVideoFormatDescription?
    private var frame: [Data] = []        // NAL units of the access unit being built
    private var sentFirst = false

    init(port: UInt16, display: MirrorDisplayView, onEvent: @escaping @MainActor @Sendable (Event) -> Void) {
        connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        self.display = display
        self.onEvent = onEvent
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish()
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func cancel() {
        queue.async {
            self.cancelled = true
            self.connection.cancel()
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.gotData = true
                self.buffer.append(data)
                self.parse()
            }
            if isComplete || error != nil { self.finish(); return }
            self.receive()
        }
    }

    private func finish() {
        guard !cancelled else { return }
        cancelled = true
        connection.cancel()
        let gotData = gotData
        let onEvent = onEvent
        Task { @MainActor in onEvent(.closed(gotData: gotData)) }
    }

    /// Splits the Annex B byte stream on start codes. The last NAL stays in the
    /// buffer until the next start code proves it's complete.
    private func parse() {
        var starts: [(at: Int, length: Int)] = []
        buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let b = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + 3 <= b.count {
                if b[i] == 0, b[i + 1] == 0 {
                    if b[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                    if i + 4 <= b.count, b[i + 2] == 0, b[i + 3] == 1 { starts.append((i, 4)); i += 4; continue }
                }
                i += 1
            }
        }
        guard starts.count >= 2 else { return }
        let base = buffer.startIndex
        for k in 0..<(starts.count - 1) {
            let from = base + starts[k].at + starts[k].length
            let to = base + starts[k + 1].at
            if to > from { handle(nal: Data(buffer[from..<to])) }
        }
        buffer = Data(buffer[(base + starts[starts.count - 1].at)...])
    }

    private func handle(nal: Data) {
        guard let header = nal.first else { return }
        let type = header & 0x1f
        switch type {
        case 7:      // SPS: a new stream (start, or the phone rotated)
            flushFrame()
            sps = nal; format = nil
        case 8:      // PPS
            flushFrame()
            pps = nal; format = nil
            makeFormat()
        case 1, 5:   // a slice; first_mb_in_slice == 0 (ue(v) "1" bit) starts a new picture
            if nal.count > 1, nal[nal.startIndex + 1] & 0x80 != 0 { flushFrame() }
            frame.append(nal)
        case 9:      // access unit delimiter
            flushFrame()
        default:
            break    // SEI and friends: not needed for display
        }
    }

    private func makeFormat() {
        guard let sps, let pps else { return }
        var description: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { s in
            pps.withUnsafeBytes { p in
                let pointers = [s.bindMemory(to: UInt8.self).baseAddress!, p.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sps.count, pps.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            }
        }
        guard status == noErr, let description else { return }
        format = description
        let dims = CMVideoFormatDescriptionGetDimensions(description)
        let size = CGSize(width: Int(dims.width), height: Int(dims.height))
        let first = !sentFirst
        sentFirst = true
        let onEvent = onEvent
        Task { @MainActor in onEvent(first ? .firstFrame(size) : .resized(size)) }
    }

    /// Packs the collected slices as one AVCC sample (4-byte lengths) and shows it now.
    private func flushFrame() {
        guard !frame.isEmpty else { return }
        defer { frame.removeAll(keepingCapacity: true) }
        guard let format else { return }
        var avcc = Data(capacity: frame.reduce(0) { $0 + $1.count + 4 })
        for nal in frame {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }
        guard let sample = Self.sampleBuffer(avcc, format: format) else { return }
        display.enqueue(sample)
    }

    private static func sampleBuffer(_ data: Data, format: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        let length = data.count
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                                                 offsetToData: 0, dataLength: length, flags: 0,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        var sizes = [length]
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                        sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil,
                                        sampleSizeEntryCount: 1, sampleSizeArray: &sizes,
                                        sampleBufferOut: &sample) == noErr, let sample else { return nil }
        // Live: show each frame as soon as it's decoded, no clock.
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

// MARK: - Display

/// A layer-backed view holding the decoder/renderer. Safe to enqueue from the stream's queue.
final class MirrorDisplayView: NSView {
    /// Unsafe: set up on the main thread; its renderer takes samples from any thread.
    nonisolated(unsafe) private let videoLayer = AVSampleBufferDisplayLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.videoGravity = .resizeAspect
        videoLayer.frame = bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(videoLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        videoLayer.frame = bounds
    }

    nonisolated func enqueue(_ sample: CMSampleBuffer) {
        let renderer = videoLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    func reset() {
        videoLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }
}

/// Puts the shared display view into whichever SwiftUI spot is showing the mirror.
struct MirrorHost: NSViewRepresentable {
    let placement: PhoneMirror.Placement

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        let mirror = PhoneMirror.shared
        guard mirror.placement == placement else { return }
        let display = mirror.display
        if display.superview !== container {
            display.removeFromSuperview()
            display.frame = container.bounds
            display.autoresizingMask = [.width, .height]
            container.addSubview(display)
        }
    }
}

/// The full-screen window's content: the phone, as large as fits.
private struct MirrorWindowContent: View {
    @ObservedObject private var mirror = PhoneMirror.shared

    var body: some View {
        ZStack {
            Color.black
            MirrorHost(placement: .window)
                .aspectRatio(mirror.videoSize.map { $0.width / max($0.height, 1) } ?? 0.46, contentMode: .fit)
        }
        .ignoresSafeArea()
    }
}
