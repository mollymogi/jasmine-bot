import SwiftUI
import PhotosUI
import JasmineMobileCore

struct ChatRoomDetailView: View {
    @Bindable var store: AppStoreModel
    let roomSummary: ChatRoomSummary

    @State private var detail: ChatRoomDetail?
    @State private var inputText = ""
    @State private var isSending = false
    @State private var showingTerminal = false
    @State private var terminalText = "正在读取主机实时终端…"
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var uploadedPaths: [String] = []
    @State private var errorBanner: String?
    @State private var pollTask: Task<Void, Never>?

    private var members: [RoomMemberItem] {
        detail?.members ?? roomSummary.members ?? []
    }

    private var messages: [ChatMessageItem] {
        detail?.normalizedMessages ?? []
    }

    private var isRoomWorking: Bool {
        messages.contains(where: \.isWorking) || (store.rooms.first(where: { $0.id == roomSummary.id })?.busy == true)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let errorBanner {
                Text(errorBanner)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(messages) { msg in
                            MessageBubbleView(
                                message: msg,
                                member: members.first { $0.id == msg.memberId }
                            )
                            .id(msg.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .onChange(of: messages.count) { _, _ in
                    if let lastId = messages.last?.id {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }

            Divider()

            // Quick @member bar for multi-agent group chats
            if members.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(members) { m in
                            Button {
                                let mention = "@\(m.id) "
                                if !inputText.contains(mention) {
                                    inputText = mention + inputText
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    BrandAvatarView(brand: m.brand, size: 18)
                                    Text("@\(m.name)")
                                        .font(.caption.weight(.medium))
                                }
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                }
            }

            if !uploadedPaths.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(uploadedPaths, id: \.self) { p in
                            HStack(spacing: 4) {
                                Image(systemName: "paperclip")
                                Text((p as NSString).lastPathComponent)
                                    .lineLimit(1)
                                Button {
                                    uploadedPaths.removeAll { $0 == p }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                            }
                            .font(.caption2)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)
                }
            }

            // Composer with PhotosPicker, Native Hold-to-Dictate & Stop/Send
            HStack(alignment: .bottom, spacing: 8) {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary)
                }
                .onChange(of: selectedPhoto) { _, item in
                    guard let item else { return }
                    Task { await uploadPickedPhoto(item) }
                }

                TextField("给 \(roomSummary.title) 派任务…", text: $inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 18))

                Button {
                    Task {
                        if store.speech.isRecording {
                            store.speech.stopRecording()
                            if !store.speech.transcript.isEmpty {
                                inputText = (inputText.isEmpty ? "" : inputText + " ") + store.speech.transcript
                            }
                        } else {
                            await store.speech.startRecording()
                        }
                    }
                } label: {
                    Image(systemName: store.speech.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(store.speech.isRecording ? Color.red : Color.accentColor)
                }

                if isRoomWorking && inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        Task { await stopExecution() }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(.red, in: Circle())
                    }
                } else {
                    Button {
                        Task { await sendCurrentMessage() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.4))
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .navigationTitle(roomSummary.title)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    showingTerminal = true
                    Task {
                        terminalText = (try? await store.client.fetchRoomTerminalSnapshot(roomId: roomSummary.id))
                            ?? "无法读取实时终端"
                    }
                } label: {
                    Label("实时终端", systemImage: "terminal")
                }
            }
        }
        .sheet(isPresented: $showingTerminal) {
            NavigationStack {
                ScrollView {
                    Text(terminalText)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                }
                .navigationTitle("主机实时终端画面")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("刷新") {
                            Task {
                                terminalText = (try? await store.client.fetchRoomTerminalSnapshot(roomId: roomSummary.id))
                                    ?? terminalText
                            }
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("关闭") { showingTerminal = false }
                    }
                }
            }
        }
        .task {
            await loadRoom()
            pollTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if !Task.isCancelled {
                        await loadRoom()
                    }
                }
            }
        }
        .onDisappear {
            pollTask?.cancel()
        }
    }

    private var canSend: Bool {
        !isSending && (!inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !uploadedPaths.isEmpty)
    }

    private func loadRoom() async {
        do {
            let loaded = try await store.client.fetchRoom(roomId: roomSummary.id)
            self.detail = loaded
            self.errorBanner = nil
        } catch {
            self.errorBanner = error.localizedDescription
        }
    }

    private func sendCurrentMessage() async {
        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = uploadedPaths
        guard !trimmed.isEmpty || !files.isEmpty else { return }
        isSending = true
        defer { isSending = false }
        do {
            try await store.client.sendMessage(
                roomId: roomSummary.id,
                text: trimmed.isEmpty ? "请查看附件" : trimmed,
                attachmentPaths: files
            )
            inputText = ""
            uploadedPaths = []
            await loadRoom()
        } catch {
            errorBanner = error.localizedDescription
        }
    }

    private func stopExecution() async {
        try? await store.client.stopRoom(roomId: roomSummary.id)
        await loadRoom()
    }

    private func uploadPickedPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let path = try await store.client.uploadAttachment(
                roomId: roomSummary.id,
                filename: "iphone-\(Int(Date().timeIntervalSince1970)).jpg",
                mimeType: "image/jpeg",
                fileData: data
            )
            uploadedPaths.append(path)
        } catch {
            errorBanner = "上传图片失败：\(error.localizedDescription)"
        }
    }
}

private struct MessageBubbleView: View {
    let message: ChatMessageItem
    let member: RoomMemberItem?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.isUser {
                Spacer(minLength: 44)
                Text(message.displayBody)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 18))
            } else {
                BrandAvatarView(brand: member?.brand ?? .generic, size: 30)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(member?.name ?? message.speaker ?? "Bot")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        if message.isWorking {
                            HStack(spacing: 4) {
                                ProgressView().controlSize(.mini)
                                Text("执行中")
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(.green)
                            }
                        }
                    }

                    // Intermediate Phase Replies (Grok-style live progress trail)
                    if let phases = message.phaseReplies, !phases.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(phases) { phase in
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "bolt.horizontal.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.blue)
                                        .padding(.top, 2)
                                    Text(phase.text)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .padding(8)
                        .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    }

                    if !message.displayBody.isEmpty {
                        Text(message.displayBody)
                            .font(.body)
                            .textSelection(.enabled)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 10)
                            .background(Color.secondary.opacity(0.11), in: RoundedRectangle(cornerRadius: 16))
                    } else if message.isWorking {
                        Text("正在思考与调用本机工具…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .italic()
                    }

                    if let err = message.error, !err.isEmpty {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                Spacer(minLength: 24)
            }
        }
    }
}
