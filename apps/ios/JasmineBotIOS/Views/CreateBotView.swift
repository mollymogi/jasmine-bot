import SwiftUI
import JasmineMobileCore

struct CreateBotView: View {
    let client: JasmineAPIClient
    let onCreated: (ChatRoomSummary) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var requestID = UUID()
    @State private var name = ""
    @State private var devices: [BotExecutionDevice] = []
    @State private var deviceID = ""
    @State private var cliID = ""
    @State private var model: BotModelChoice?
    @State private var customModel = ""
    @State private var cwd = ""
    @State private var loading = true
    @State private var submitting = false
    @State private var error: String?

    private var device: BotExecutionDevice? { devices.first { $0.id == deviceID } }
    private var cli: BotCLIChoice? { device?.clis.first { $0.id == cliID } }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedCwd: String { cwd.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var modelName: String { model?.id ?? customModel.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var ready: Bool {
        device != nil && cli != nil && !trimmedName.isEmpty && !modelName.isEmpty && !trimmedCwd.isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Bot 名称") {
                    TextField("名称", text: $name)
                }
                if loading {
                    ProgressView("正在读取设备与 CLI")
                } else if !devices.isEmpty {
                    Section("执行设备") {
                        Picker("设备", selection: $deviceID) {
                            ForEach(devices) { node in
                                Text(node.online ? node.label : "\(node.label)（离线）").tag(node.id)
                            }
                        }
                        if device?.online == false {
                            Label("任务会在设备上线后执行", systemImage: "clock")
                                .foregroundStyle(.secondary)
                        }
                        TextField("设备上的工作目录", text: $cwd)
                            .font(.body.monospaced())
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }

                    Section("运行配置") {
                        if let device, !device.clis.isEmpty {
                            Picker("CLI", selection: $cliID) {
                                ForEach(device.clis) { option in
                                    Text(option.label ?? option.id).tag(option.id)
                                }
                            }
                            Picker("模型", selection: $model) {
                                ForEach(cli?.models ?? [], id: \.self) { option in
                                    Text(option.label ?? option.id).tag(Optional(option))
                                }
                                Text("输入模型 ID").tag(nil as BotModelChoice?)
                            }
                            if model == nil {
                                TextField("模型 ID", text: $customModel)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)
                            }
                        } else {
                            Label("设备尚未报告可用 CLI", systemImage: "terminal")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        if devices.isEmpty {
                            Button("重新加载") { Task { await loadDevices() } }
                        }
                    }
                }
            }
            .disabled(submitting)
            .navigationTitle("创建 Bot")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(submitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitting ? "创建中…" : "创建") { Task { await submit() } }
                        .disabled(!ready || submitting)
                }
            }
            .onChange(of: deviceID) { _, _ in selectDeviceDefaults() }
            .onChange(of: cliID) { _, _ in selectModelDefault() }
            .task { await loadDevices() }
            .interactiveDismissDisabled(submitting)
        }
    }

    private func selectModelDefault() {
        model = cli?.models?.first
        customModel = ""
    }

    private func selectDeviceDefaults() {
        cwd = device?.defaultCwd ?? ""
        cliID = device?.clis.first?.id ?? ""
        selectModelDefault()
    }

    private func loadDevices() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            devices = try await client.executionDevices()
            deviceID = devices.first(where: { !$0.clis.isEmpty })?.id ?? devices.first?.id ?? ""
            selectDeviceDefaults()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func submit() async {
        guard !submitting, ready, let device else { return }
        submitting = true
        error = nil
        defer { submitting = false }
        do {
            let draft = BotCreationRequest(id: requestID, name: trimmedName, device: device,
                                          cli: cliID, model: modelName,
                                          source: model.map { $0.source ?? "native" } ?? "custom", cwd: trimmedCwd)
            let room = try await client.createBot(draft)
            onCreated(room)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
