import Foundation
import AVFoundation
import Speech
import Observation

/// Native iOS Speech-to-Text + Spoken Reply service (bypasses Safari HTTP getUserMedia restrictions).
@Observable
@MainActor
public final class SpeechService {
    public var isRecording = false
    public var transcript = ""
    public var errorMessage: String?
    public var speakRepliesAloud = true

    private lazy var speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private lazy var audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private lazy var synthesizer = AVSpeechSynthesizer()

    public init() {}

    private nonisolated static func requestSpeechAuth() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    private nonisolated static func installAudioTap(
        on inputNode: AVAudioInputNode,
        format: AVAudioFormat,
        request: SFSpeechAudioBufferRecognitionRequest
    ) {
        inputNode.removeTap(onBus: 0)
        nonisolated(unsafe) let unsafeRequest = request
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            unsafeRequest.append(buffer)
        }
    }

    private nonisolated static func startSpeechTask(
        recognizer: SFSpeechRecognizer?,
        request: SFSpeechAudioBufferRecognitionRequest,
        onUpdate: @escaping @Sendable (String?, Bool) -> Void
    ) -> SFSpeechRecognitionTask? {
        recognizer?.recognitionTask(with: request) { result, error in
            let latestText = result?.bestTranscription.formattedString
            let shouldStop = error != nil || (result?.isFinal == true)
            onUpdate(latestText, shouldStop)
        }
    }

    public func requestPermissions() async -> Bool {
        let speechStatus = await Self.requestSpeechAuth()
        guard speechStatus == .authorized else {
            errorMessage = "请在系统设置中开启「语音识别」权限"
            return false
        }
        #if os(iOS)
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            errorMessage = "请在系统设置中开启「麦克风」权限"
            return false
        }
        #endif
        return true
    }

    public func startRecording() async {
        guard !isRecording else { return }
        errorMessage = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        guard await requestPermissions() else { return }
        stopRecording()

        do {
            #if os(iOS)
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .duckOthers, .allowBluetoothA2DP])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            #endif

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.recognitionRequest = request

            let inputNode = audioEngine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            Self.installAudioTap(on: inputNode, format: recordingFormat, request: request)

            audioEngine.prepare()
            try audioEngine.start()
            transcript = ""
            isRecording = true

            recognitionTask = Self.startSpeechTask(recognizer: speechRecognizer, request: request) { [weak self] latestText, shouldStop in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let latestText {
                        self.transcript = latestText
                    }
                    if shouldStop {
                        self.stopRecording()
                    }
                }
            }
        } catch {
            errorMessage = "启动录音失败：\(error.localizedDescription)"
            stopRecording()
        }
    }

    public func stopRecording() {
        if audioEngine.isRunning {
            audioEngine.stop()
            audioEngine.inputNode.removeTap(onBus: 0)
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        isRecording = false
    }

    public func speak(_ text: String) {
        guard speakRepliesAloud else { return }
        let cleaned = text
            .replacingOccurrences(of: #"`[^`]*`"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[#*>-]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: String(cleaned.prefix(400)))
        utterance.voice = AVSpeechSynthesisVoice(language: "zh-CN")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.06
        synthesizer.speak(utterance)
    }
}
