//
//  SystemTTSClient.swift
//  leanring-buddy
//
//  Speaks text with the built-in macOS voices, so no TTS API key or server
//  is needed (speakText / isPlaying / stopPlayback).
//
//  Speech is rendered to audio buffers (AVSpeechSynthesizer.write) and played
//  through AVAudioEngine. The whole reply is rendered as ONE utterance, so
//  there are no joins between sentences where words could get swallowed.
//  Playback starts once a short head start of audio is buffered; rendering
//  runs several times faster than real time, so it stays ahead. A short
//  silent lead-in wakes the audio output before the first word.
//

import AVFoundation
import Foundation

@MainActor
final class SystemTTSClient {
    private let synthesizer = AVSpeechSynthesizer()
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var connectedAudioFormat: AVAudioFormat?

    /// Audio buffered before playback starts, so rendering stays ahead.
    private static let headStartSeconds = 0.4
    /// Silence played first so the audio output is awake for the first word.
    private static let leadInSilenceSeconds = 0.15

    /// Bumped on every new utterance or stop, so late callbacks from an
    /// earlier utterance are ignored.
    private var playbackGeneration = 0
    private var pendingBufferCount = 0
    private var isRenderingComplete = true
    private var hasStartedPlayback = false
    /// Rendered buffers waiting for the head start to fill up.
    private var bufferedBeforeStart: [AVAudioPCMBuffer] = []
    private var bufferedBeforeStartSeconds = 0.0
    /// Resumed once playback starts, so speakText returns when speech is audible.
    private var playbackStartedContinuation: CheckedContinuation<Void, Never>?

    /// Whether speech is currently playing (or still being prepared).
    private(set) var isPlaying = false

    init() {
        audioEngine.attach(playerNode)
    }

    /// Installed voices for a language, best quality first (Premium, Enhanced, then default).
    /// More voices can be downloaded in System Settings > Accessibility > System Voice.
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
        await speak(text, voice: Self.selectedVoice())
    }

    /// Speaks a sample sentence with a specific voice (Settings > Voice preview).
    func speakPreview(voice: AVSpeechSynthesisVoice?) {
        Task {
            await speak("hey, i'm yoclicky. this is how i sound.", voice: voice)
        }
    }

    /// Stops any in-progress speech immediately.
    func stopPlayback() {
        playbackGeneration += 1
        synthesizer.stopSpeaking(at: .immediate)
        playerNode.stop()
        pendingBufferCount = 0
        isRenderingComplete = true
        hasStartedPlayback = false
        bufferedBeforeStart = []
        bufferedBeforeStartSeconds = 0
        isPlaying = false
        resumePlaybackStartedContinuation()
    }

    // MARK: - Rendering and playback

    /// Renders `text` as one utterance and streams it to the player.
    /// Returns once playback has started (or nothing could be rendered).
    private func speak(_ text: String, voice: AVSpeechSynthesisVoice?) async {
        stopPlayback()
        let generation = playbackGeneration
        isPlaying = true
        isRenderingComplete = false
        let renderStartTime = Date()

        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        utterance.rate = Float(ClickySettings.speechRate)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            playbackStartedContinuation = continuation

            synthesizer.write(utterance) { [weak self] audioBuffer in
                guard let pcmBuffer = audioBuffer as? AVAudioPCMBuffer else { return }
                // Hop to the main thread in order (DispatchQueue.main is FIFO).
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.handleRenderedBuffer(pcmBuffer, generation: generation, renderStartTime: renderStartTime, voiceName: voice?.name)
                    }
                }
            }
        }
    }

    private func handleRenderedBuffer(_ pcmBuffer: AVAudioPCMBuffer, generation: Int, renderStartTime: Date, voiceName: String?) {
        guard generation == playbackGeneration else { return }

        // A zero-length buffer marks the end of rendering.
        if pcmBuffer.frameLength == 0 {
            if !hasStartedPlayback {
                startPlayback(generation: generation, renderStartTime: renderStartTime, voiceName: voiceName)
            }
            isRenderingComplete = true
            updatePlayingState()
            return
        }

        if hasStartedPlayback {
            schedule(pcmBuffer, generation: generation)
            return
        }

        bufferedBeforeStart.append(pcmBuffer)
        bufferedBeforeStartSeconds += Double(pcmBuffer.frameLength) / pcmBuffer.format.sampleRate
        if bufferedBeforeStartSeconds >= Self.headStartSeconds {
            startPlayback(generation: generation, renderStartTime: renderStartTime, voiceName: voiceName)
        }
    }

    private func startPlayback(generation: Int, renderStartTime: Date, voiceName: String?) {
        hasStartedPlayback = true
        let buffersToPlay = bufferedBeforeStart
        bufferedBeforeStart = []
        bufferedBeforeStartSeconds = 0

        guard let audioFormat = buffersToPlay.first?.format, prepareAudioEngine(for: audioFormat) else {
            isRenderingComplete = true
            updatePlayingState()
            resumePlaybackStartedContinuation()
            return
        }

        if let leadInSilence = Self.makeSilence(seconds: Self.leadInSilenceSeconds, format: audioFormat) {
            schedule(leadInSilence, generation: generation)
        }
        for buffer in buffersToPlay {
            schedule(buffer, generation: generation)
        }
        playerNode.play()
        print("🔊 System TTS: \(voiceName ?? "default voice"), first audio after \(String(format: "%.2f", Date().timeIntervalSince(renderStartTime)))s")
        resumePlaybackStartedContinuation()
    }

    /// Connects the player for `audioFormat` and makes sure the engine runs.
    private func prepareAudioEngine(for audioFormat: AVAudioFormat) -> Bool {
        if connectedAudioFormat != audioFormat {
            audioEngine.disconnectNodeOutput(playerNode)
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: audioFormat)
            connectedAudioFormat = audioFormat
        }
        guard !audioEngine.isRunning else { return true }
        do {
            try audioEngine.start()
            return true
        } catch {
            print("⚠️ System TTS: couldn't start audio engine: \(error)")
            return false
        }
    }

    private func schedule(_ buffer: AVAudioPCMBuffer, generation: Int) {
        pendingBufferCount += 1
        playerNode.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.bufferFinishedPlaying(generation: generation)
                }
            }
        }
    }

    private func bufferFinishedPlaying(generation: Int) {
        guard generation == playbackGeneration else { return }
        pendingBufferCount = max(0, pendingBufferCount - 1)
        updatePlayingState()
    }

    private func updatePlayingState() {
        if isRenderingComplete && pendingBufferCount == 0 {
            isPlaying = false
        }
    }

    private func resumePlaybackStartedContinuation() {
        playbackStartedContinuation?.resume()
        playbackStartedContinuation = nil
    }

    private static func makeSilence(seconds: Double, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(seconds * format.sampleRate)
        guard let silenceBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return nil }
        // New buffers are zero-filled, which is silence for PCM.
        silenceBuffer.frameLength = frameCount
        return silenceBuffer
    }
}
