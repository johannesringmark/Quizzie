import AVFoundation

final class BlockingPlayer {
    func playBlocking(name: String, ext: String = "mp3") async throws {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            print("File not found")
            throw NSError(domain: "BlockingPlayer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "File not found"])
        }

        let session = AVAudioSession.sharedInstance()
        //try session.setCategory(.playback, mode: .default)
        //try session.setActive(true)

        let player = try AVAudioPlayer(contentsOf: url)
        let sema = DispatchSemaphore(value: 0)

        // Per-call delegate so there's no cross-talk between plays.
        final class DelegateBox: NSObject, AVAudioPlayerDelegate {
            let done: () -> Void
            init(done: @escaping () -> Void) { self.done = done }
            func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { done() }
            func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { done() }
        }
        let delegateBox = DelegateBox { sema.signal() }

        player.delegate = delegateBox
        player.prepareToPlay()
        player.play()

        // Keep strong refs to player & delegate until playback finishes.
        _ = withExtendedLifetime((player, delegateBox)) {
            sema.wait() // ⚠️ call off the main thread
        }

        // Optionally: try? session.setActive(false)  // if you want to relinquish the session
    }
}
