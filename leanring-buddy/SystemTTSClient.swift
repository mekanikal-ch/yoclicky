//
//  SystemTTSClient.swift
//  leanring-buddy
//
//  Speaks text with the built-in macOS voices via AVSpeechSynthesizer.
//  Replaces ElevenLabsTTSClient so no TTS API key or proxy is needed.
//  Same interface as ElevenLabsTTSClient (speakText / isPlaying / stopPlayback).
//

import AVFoundation
import Foundation

@MainActor
final class SystemTTSClient {
    private let synthesizer = AVSpeechSynthesizer()

    /// Prefer the highest-quality installed English voice. Premium/enhanced
    /// voices can be downloaded in System Settings > Accessibility > Spoken Content.
    /// Override with the `ttsVoiceIdentifier` user default.
    private lazy var voice: AVSpeechSynthesisVoice? = {
        if let voiceIdentifier = UserDefaults.standard.string(forKey: "ttsVoiceIdentifier"),
           let overrideVoice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            return overrideVoice
        }
        let englishVoices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "en-US" }
        return englishVoices.first(where: { $0.quality == .premium })
            ?? englishVoices.first(where: { $0.quality == .enhanced })
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    /// Starts speaking `text` and returns once playback has begun.
    func speakText(_ text: String) async throws {
        try Task.checkCancellation()
        stopPlayback()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synthesizer.speak(utterance)
        print("🔊 System TTS: speaking with \(voice?.name ?? "default voice")")
    }

    /// Whether speech is currently playing back.
    var isPlaying: Bool {
        synthesizer.isSpeaking
    }

    /// Stops any in-progress speech immediately.
    func stopPlayback() {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }
}
