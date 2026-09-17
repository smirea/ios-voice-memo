import AVFoundation

@MainActor
final class AudioSessionController {
	static let shared = AudioSessionController()
	private var owner: ObjectIdentifier?

	func activate(
		_ owner: AnyObject,
		category: AVAudioSession.Category,
		mode: AVAudioSession.Mode,
		options: AVAudioSession.CategoryOptions = []
	) throws {
		let session = AVAudioSession.sharedInstance()
		try session.setCategory(category, mode: mode, options: options)
		try session.setActive(true)
		self.owner = ObjectIdentifier(owner)
	}

	func deactivate(_ owner: AnyObject) {
		guard self.owner == ObjectIdentifier(owner) else { return }
		self.owner = nil
		try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
	}

	func invalidate(_ owner: AnyObject) {
		guard self.owner == ObjectIdentifier(owner) else { return }
		self.owner = nil
	}
}
