import AppKit

@MainActor
enum SoundPlayer {
    private static var current: NSSound?

    static func playCapture() {
        play(systemSoundNamed: "Tink", fallbackPath: "/System/Library/Sounds/Tink.aiff")
    }

    static func playRecordingStart() {
        play(systemSoundNamed: "Pop", fallbackPath: "/System/Library/Sounds/Pop.aiff")
    }

    static func playRecordingStop() {
        play(systemSoundNamed: "Bottle", fallbackPath: "/System/Library/Sounds/Bottle.aiff")
    }

    private static func play(systemSoundNamed name: String, fallbackPath: String) {
        guard AppServices.shared.settings.playSounds else { return }
        let sound = NSSound(named: name) ?? NSSound(contentsOfFile: fallbackPath, byReference: true)
        current = sound
        sound?.play()
    }
}
