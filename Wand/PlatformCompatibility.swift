import Combine
import SwiftUI

final class SpeechRecognizerService: ObservableObject {
    @Published private(set) var transcript = ""
    @Published private(set) var isRecording = false
    @Published private(set) var usingOnDevice = false

    func start(onError: @escaping (String) -> Void) {
        onError("macOS 暂不支持语音输入")
    }

    func stop(cancelled: Bool, commit: ((String) -> Void)? = nil) {}
}
