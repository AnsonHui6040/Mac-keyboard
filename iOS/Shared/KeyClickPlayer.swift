import AVFoundation
import RemoteKeyboardCore
import os

/// Plays the key click at the level the user chose (D23). `UIDevice.playInputClick()` has a fixed volume, so the keyboard
/// and the Settings preview play the click themselves through `AVAudioEngine`: player node, then an EQ whose global
/// gain amplifies above 100%, then the main mixer. The sound is iOS's own `key_press_click.caf`, read from the system
/// at run time (nothing of it is copied into the project); when that file cannot be read, the click synthesised by
/// `scripts/make-key-click.swift` and bundled as `key-click.caf` is used. The audio session is `.ambient` with
/// `.mixWithOthers`: the iPhone silent switch mutes it and music keeps playing.
///
/// The engine only runs between `begin()` and `stop()`, so a keyboard that is not on screen costs no power. Any
/// failure returns false from `play`, and the caller falls back to the system click. Logs hold event kinds only.
@MainActor
final class KeyClickPlayer {
    static let shared = KeyClickPlayer()

    enum Source: String {
        case system
        case bundled
    }

    static let systemClickPath = "/System/Library/Audio/UISounds/key_press_click.caf"
    private static let log = Logger(subsystem: "com.ansonhui.remotekeyboard", category: "feedback")

    /// Where the loaded click came from; nil until the first successful load.
    private(set) var source: Source?
    private var buffer: AVAudioPCMBuffer?
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var eq: AVAudioUnitEQ?
    /// A start failed (logged once); later presses and `prepare()` calls go straight to the system click until the next
    /// `begin()`.
    private var failed = false

    var isRunning: Bool { engine?.isRunning == true }

    /// Reads the system click, or the bundled one, into memory.
    static func loadBuffer() -> (buffer: AVAudioPCMBuffer, source: Source)? {
        var candidates: [(URL, Source)] = [(URL(fileURLWithPath: systemClickPath), .system)]
        if let bundled = Bundle.main.url(forResource: "key-click", withExtension: "caf") {
            candidates.append((bundled, .bundled))
        }
        for (url, source) in candidates {
            guard
                let file = try? AVAudioFile(forReading: url), file.length > 0,
                let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
                (try? file.read(into: buffer)) != nil, buffer.frameLength > 0
            else { continue }
            return (buffer, source)
        }
        return nil
    }

    /// A new session of use (the keyboard appeared, or the Settings page appeared): forget an earlier failure and start
    /// the engine if it is not running.
    @discardableResult
    func begin() -> Bool {
        failed = false
        return ensureRunning()
    }

    /// Starts the engine if it is not running, unless a start already failed in this session of use. Safe to call often.
    @discardableResult
    func prepare() -> Bool {
        guard !failed else { return false }
        return ensureRunning()
    }

    /// Plays one click at `volume` (0…2). Returns true when the click was handled, which includes volume 0 (silence);
    /// false means the caller should play the system click instead.
    func play(volume: Double) -> Bool {
        let output = KeyFeedbackSettings.output(forVolume: volume)
        guard output.nodeVolume > 0 else { return true }
        guard !failed, ensureRunning(), let player, let eq, let buffer else { return false }
        player.volume = output.nodeVolume
        eq.globalGain = output.gainDB
        player.scheduleBuffer(buffer, at: nil, options: .interrupts, completionHandler: nil)
        return true
    }

    /// Stops the engine and gives the audio session back.
    func stop() {
        guard engine != nil else { return }
        player?.stop()
        engine?.stop()
        engine = nil
        player = nil
        eq = nil
        try? AVAudioSession.sharedInstance().setActive(false)
        Self.log.info("click engine stopped")
    }

    private func ensureRunning() -> Bool {
        if isRunning { return true }
        // A configuration change or an interruption stops the engine; build a fresh graph.
        engine?.stop()
        engine = nil; player = nil; eq = nil
        if buffer == nil, let loaded = Self.loadBuffer() {
            buffer = loaded.buffer
            source = loaded.source
        }
        guard let buffer else {
            failed = true
            Self.log.error("click sound unavailable")
            return false
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
            try? session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)
            let engine = AVAudioEngine()
            let player = AVAudioPlayerNode()
            let eq = AVAudioUnitEQ(numberOfBands: 1)
            // Only the global gain is used; the one band must not filter anything.
            eq.bands[0].bypass = true
            engine.attach(player)
            engine.attach(eq)
            engine.connect(player, to: eq, format: buffer.format)
            engine.connect(eq, to: engine.mainMixerNode, format: buffer.format)
            engine.prepare()
            try engine.start()
            player.play()
            self.engine = engine; self.player = player; self.eq = eq
            Self.log.info("click engine started, source \(self.source?.rawValue ?? "none", privacy: .public)")
            return true
        } catch {
            failed = true
            Self.log.error("click engine failed to start: \((error as NSError).code, privacy: .public)")
            return false
        }
    }
}
