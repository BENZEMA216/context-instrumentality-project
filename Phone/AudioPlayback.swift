import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioPlayback: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var errorMessage: String?
    private var player: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?

    override init() {
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
            Task { @MainActor [weak self] in self?.handleInterruption(rawType) }
        }
    }

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
    }

    var currentTime: TimeInterval { player?.currentTime ?? 0 }
    var duration: TimeInterval { player?.duration ?? 0 }

    func toggle(url: URL) {
        if isPlaying {
            player?.pause()
            isPlaying = false
            return
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            if player == nil {
                let newPlayer = try AVAudioPlayer(contentsOf: url)
                newPlayer.delegate = self
                guard newPlayer.prepareToPlay() else { throw PlaybackError.cannotPlay }
                player = newPlayer
            }
            guard player?.play() == true else { throw PlaybackError.cannotPlay }
            errorMessage = nil
            isPlaying = true
        } catch {
            errorMessage = "无法播放：\(error.localizedDescription)"
            stop()
        }
    }

    func seek(to value: TimeInterval) { player?.currentTime = max(0, min(value, duration)) }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func handleInterruption(_ rawType: UInt) {
        guard let type = AVAudioSession.InterruptionType(rawValue: rawType), player != nil else { return }
        // AVAudioPlayer does not send its completion callback for interruptions.
        // Pause without discarding the player so a later user tap keeps position.
        player?.pause()
        isPlaying = false
        switch type {
        case .began: errorMessage = "回听被系统中断，结束后可手动继续。"
        case .ended: errorMessage = "中断已结束，点击播放继续回听。"
        @unknown default: errorMessage = "回听已暂停，请手动继续。"
        }
        // Deliberately ignore shouldResume: resuming requires an explicit tap.
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            self?.stop()
            if !flag { self?.errorMessage = "播放未正常完成。" }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let message = error?.localizedDescription ?? "音频解码失败。"
        Task { @MainActor [weak self] in self?.errorMessage = message; self?.stop() }
    }

    private enum PlaybackError: LocalizedError {
        case cannotPlay
        var errorDescription: String? { "系统未能开始音频播放。" }
    }
}
