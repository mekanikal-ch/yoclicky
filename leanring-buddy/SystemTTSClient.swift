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

    /// Installed voices for a language, best quality first (Premium, Enhanced, then default).
    /// More voices can be downloaded in System Settings > Accessibility > Spoken Content.
    static func availableVoices(for language: AssistantLanguage) -> [AVSpeechSynthesisVoice] {
        let languagePrefix = language.languageCode
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(languagePrefix) }
            .sorted { firstVoice, secondVoice in
                if firstVoice.quality != secondVoice.quality {
                    return firstVoice.quality.rawValue > secondVoice.quality.rawValue
                }
                return firstVoice.name < secondVoice.name
            }
    }

    /// The voice picked in Settings > Voice if it matches the chosen language,
    /// otherwise the best installed voice for that language.
    static func selectedVoice() -> AVSpeechSynthesisVoice? {
        let language = ClickySettings.language
        if let voiceIdentifier = UserDefaults.standard.string(forKey: ClickySettings.ttsVoiceIdentifierKey),
           let chosenVoice = AVSpeechSynthesisVoice(identifier: voiceIdentifier),
           chosenVoice.language.hasPrefix(language.languageCode) {
            return chosenVoice
        }
        return availableVoices(for: language).first ?? AVSpeechSynthesisVoice(language: language.locale.identifier)
    }

    /// Starts speaking `text` and returns once playback has begun.
    func speakText(_ text: String) async throws {
        try Task.checkCancellation()
        speak(text, voice: Self.selectedVoice())
    }

    /// Speaks a sample sentence with a specific voice (Settings > Voice preview).
    func speakPreview(voice: AVSpeechSynthesisVoice?) {
        speak("hey, i'm yoclicky. this is how i sound.", voice: voice)
    }

    private func speak(_ text: String, voice: AVSpeechSynthesisVoice?) {
        stopPlayback()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = Float(ClickySettings.speechRate)
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
