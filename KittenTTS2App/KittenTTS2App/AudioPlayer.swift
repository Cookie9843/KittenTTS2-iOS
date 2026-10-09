import AVFoundation

/// Plays local WAV files with AVAudioPlayer and reports when playback ends.
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    var onFinish: (() -> Void)?

    func play(url: URL) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        let player = try AVAudioPlayer(contentsOf: url)
        player.delegate = self
        guard player.prepareToPlay(), player.play() else {
            throw NSError(domain: "AudioPlayer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Audio playback could not be started."])
        }
        self.player = player
    }

    func stop() {
        player?.stop()
        player = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        self.player = nil
        onFinish?()
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        self.player = nil
        onFinish?()
    }
}
