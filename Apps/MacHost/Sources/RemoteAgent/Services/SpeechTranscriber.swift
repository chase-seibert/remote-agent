import AVFoundation
import Speech

@MainActor
final class SpeechTranscriber: NSObject, ObservableObject {
  @Published private(set) var isRecording = false
  @Published private(set) var authorizationDenied = false

  private let audioEngine = AVAudioEngine()
  private let recognizer = SFSpeechRecognizer(locale: Locale.current)
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?

  func toggle(onText: @escaping (String) -> Void) {
    if isRecording {
      stop()
    } else {
      Task { await start(onText: onText) }
    }
  }

  func stop() {
    guard isRecording else { return }
    audioEngine.stop()
    audioEngine.inputNode.removeTap(onBus: 0)
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil
    isRecording = false
  }

  private func start(onText: @escaping (String) -> Void) async {
    let status = await withCheckedContinuation { continuation in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
    }
    guard status == .authorized else {
      authorizationDenied = true
      return
    }

    stop()
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.shouldReportPartialResults = true
    self.request = request

    let inputNode = audioEngine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
      request.append(buffer)
    }

    task = recognizer?.recognitionTask(with: request) { result, error in
      Task { @MainActor in
        if let result { onText(result.bestTranscription.formattedString) }
        if error != nil || result?.isFinal == true { self.stop() }
      }
    }

    do {
      audioEngine.prepare()
      try audioEngine.start()
      isRecording = true
    } catch {
      stop()
    }
  }
}
