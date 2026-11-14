//
//  AudioPlayer.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 09/08/24.
//

import Foundation
import AppKit

final class AudioPlayer: NSObject, NSSoundDelegate {
    /// Playing sounds must be retained or playback is cut off when ARC
    /// releases the instance at the end of the statement.
    private var sound: NSSound?

    func play(fileName: String, fileExtension: String) {
        guard let url = Bundle.main.url(forResource: fileName, withExtension: fileExtension),
              let sound = NSSound(contentsOf: url, byReference: false) else { return }
        play(sound)
    }

    /// Plays one of the macOS alert sounds (e.g. "Glass").
    func play(systemSoundNamed name: String) {
        guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        play(sound)
    }

    func stop() {
        sound?.stop()
        sound = nil
    }

    private func play(_ sound: NSSound) {
        self.sound?.stop()
        sound.delegate = self
        self.sound = sound
        sound.play()
    }

    func sound(_ sound: NSSound, didFinishPlaying flag: Bool) {
        // A sound stopped to make way for a new one also reports finishing;
        // don't let it release its replacement.
        if sound === self.sound {
            self.sound = nil
        }
    }
}
