import SwiftUI
import JasmineMobileCore

struct VoiceConsoleView: View {
    @Bindable var store: AppStoreModel
    @State private var targetRoomId: String = ""
    @State private var statusBanner: String?
    @State private var latestBotAnswer: String = ""

    private var activeRoom: ChatRoomSummary? {
        store.rooms.first { $0.id == targetRoomId } ?? store.rooms.first
    }

    var body: some View {
        @Bindable var speech = store.speech
        NavigationStack {
            VStack(spacing: 24) {
                if !store.rooms.isEmpty {
                    Picker("派活目标", selection: $targetRoomId) {
                        ForEach(store.rooms) { r in
                            Text(r.title).tag(r.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .padding(.top, 8)
                }

                Toggle("语音播报 Bot 回复", isOn: $speech.speakRepliesAloud)
                    .font(.subheadline)
                    .padding(.horizontal, 28)

                Spacer()

                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(store.speech.isRecording ? Color.red.opacity(0.16) : Color.accentColor.opacity(0.12))
                            .frame(width: 150, height: 150)
                            .scaleEffect(store.speech.isRecording ? 1.12 : 1.0)
                            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: store.speech.isRecording)

                        Button {
                            Task { await toggleVoiceTurn() }
                        } label: {
                            Image(systemName: store.speech.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 46, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 108, height: 108)
                                .background(store.speech.isRecording ? Color.red : Color.accentColor, in: Circle())
                                .shadow(radius: 8)
                        }
                    }

                    Text(store.speech.isRecording ? "正在聆听… 再点一次立即发送给 Bot" : "点击开始说话，松手派发任务")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if !store.speech.transcript.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("识别内容")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(store.speech.transcript)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(14)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)
                }

                if !latestBotAnswer.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("最新回复")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(latestBotAnswer)
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(14)
                    }
                    .frame(maxHeight: 160)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)
                }

                if let msg = statusBanner ?? store.speech.errorMessage {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
            .navigationTitle("Grok 式语音派活")
            .onAppear {
                if targetRoomId.isEmpty, let first = store.rooms.first {
                    targetRoomId = first.id
                }
            }
        }
    }

    private func toggleVoiceTurn() async {
        if store.speech.isRecording {
            store.speech.stopRecording()
            let text = store.speech.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let room = activeRoom else { return }
            statusBanner = "正在发往「\(room.title)」…"
            do {
                try await store.client.sendMessage(roomId: room.id, text: text)
                statusBanner = "已发送，等待「\(room.title)」回复…"
                // Poll briefly for completion and read aloud
                for _ in 0..<45 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    let snap = try await store.client.fetchRoom(roomId: room.id, limit: 10)
                    if let lastBot = snap.normalizedMessages.last(where: { !$0.isUser }),
                       !lastBot.isWorking, !lastBot.displayBody.isEmpty {
                        latestBotAnswer = lastBot.displayBody
                        statusBanner = nil
                        store.speech.speak(lastBot.displayBody)
                        break
                    }
                }
            } catch {
                statusBanner = "发送失败：\(error.localizedDescription)"
            }
        } else {
            statusBanner = nil
            await store.speech.startRecording()
        }
    }
}
