import AVFoundation

final class AudioManager {

    private var landPlayer:  AVAudioPlayer?
    private var crashPlayer: AVAudioPlayer?
    private let queue = DispatchQueue(label: "audio", qos: .userInteractive)

    init() {
        landPlayer  = load("Land")
        crashPlayer = load("Crash")
        queue.async { [weak self] in
            guard let self else { return }
            [landPlayer, crashPlayer].forEach { p in
                guard let p else { return }
                p.volume = 0; p.play(); p.stop(); p.currentTime = 0; p.volume = 1
            }
        }
    }

    func playLand()  { queue.async { [weak self] in self?.play(self?.landPlayer)  } }
    func playCrash() { queue.async { [weak self] in self?.play(self?.crashPlayer) } }

    private func load(_ name: String) -> AVAudioPlayer? {
        // Search next to the executable for optional sound files
        let exe = Bundle.main.bundleURL.deletingLastPathComponent()
        let url = ["mov", "mp3"].lazy
            .map { exe.appendingPathComponent("\(name).\($0)") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let url else { return nil }
        let player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        return player
    }

    private func play(_ player: AVAudioPlayer?) {
        guard let p = player else { return }
        p.currentTime = 0
        p.play()
    }
}
