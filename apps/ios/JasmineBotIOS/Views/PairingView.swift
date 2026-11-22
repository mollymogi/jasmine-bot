import SwiftUI
import AVFoundation
import JasmineMobileCore

#if os(iOS)
import UIKit

struct QRScannerSheet: UIViewControllerRepresentable {
    let onScanned: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> ScannerVC {
        let vc = ScannerVC()
        vc.onCodeDetected = { code in
            onScanned(code)
            dismiss()
        }
        return vc
    }

    func updateUIViewController(_ uiViewController: ScannerVC, context: Context) {}

    final class ScannerVC: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onCodeDetected: ((String) -> Void)?
        private let session = AVCaptureSession()
        private var previewLayer: AVCaptureVideoPreviewLayer?
        private var locked = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.frame = view.bounds
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            self.previewLayer = preview

            let captureSession = self.session
            DispatchQueue.global(qos: .userInitiated).async {
                captureSession.startRunning()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            previewLayer?.frame = view.bounds
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            if session.isRunning {
                session.stopRunning()
            }
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !locked,
                  let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = obj.stringValue, !value.isEmpty else { return }
            locked = true
            session.stopRunning()
            onCodeDetected?(value)
        }
    }
}
#endif

struct PairingView: View {
    @Bindable var store: AppStoreModel
    @State private var hostInput = ""
    @State private var tunnelInput = ""
    @State private var pinInput = ""
    @State private var qrPasteInput = ""
    @State private var showingScanner = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    VStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.14))
                                .frame(width: 72, height: 72)
                            Image(systemName: "sparkles.rectangle.stack.fill")
                                .font(.system(size: 32, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                        Text("连接你的 Jasmine Bot 主机")
                            .font(.title2.bold())
                        Text("主机常驻执行 · 手机免 VPN 随身派活、审批与语音")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 20)

                    #if os(iOS)
                    Button {
                        showingScanner = true
                    } label: {
                        Label("扫描 Mac 桌面端「iOS 全通道二维码」", systemImage: "qrcode.viewfinder")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    #endif

                    GroupBox("或输入主机地址 + 6 位 PIN 码") {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("局域网或公网隧道地址 (如 https://bot.yourdomain.com)", text: $hostInput)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.subheadline, design: .monospaced))
                                .textFieldStyle(.roundedBorder)

                            TextField("备选公网 HTTPS 隧道地址 (可选，出门 5G 免 VPN 自动切换)", text: $tunnelInput)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.subheadline, design: .monospaced))
                                .textFieldStyle(.roundedBorder)

                            TextField("6 位数字 PIN 配对码", text: $pinInput)
                                .font(.system(.title3, design: .monospaced).weight(.bold))
                                .textFieldStyle(.roundedBorder)

                            Button {
                                Task {
                                    await store.pairWithPIN(
                                        origin: hostInput,
                                        pin: pinInput,
                                        tunnelOrigin: tunnelInput
                                    )
                                }
                            } label: {
                                HStack {
                                    if store.isConnecting {
                                        ProgressView().controlSize(.small)
                                    }
                                    Text("验证 PIN 并配对")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(store.isConnecting || hostInput.trimmingCharacters(in: .whitespaces).isEmpty || pinInput.count < 6)
                        }
                        .padding(.top, 4)
                    }

                    GroupBox("粘贴扫码直连链接") {
                        VStack(spacing: 10) {
                            TextField("粘贴 jasminebot://pair?data=... 或带 ?pair= 的链接", text: $qrPasteInput)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(.caption, design: .monospaced))
                                .textFieldStyle(.roundedBorder)

                            Button("解析链接直连") {
                                Task { await store.pairWithQR(qrPasteInput) }
                            }
                            .buttonStyle(.bordered)
                            .disabled(store.isConnecting || qrPasteInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        .padding(.top, 4)
                    }

                    if let err = store.connectionError {
                        Text(err)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .navigationTitle("Jasmine Bot")
            #if os(iOS)
            .sheet(isPresented: $showingScanner) {
                NavigationStack {
                    QRScannerSheet { code in
                        Task { await store.pairWithQR(code) }
                    }
                    .ignoresSafeArea()
                    .navigationTitle("扫描桌面配对码")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showingScanner = false }
                        }
                    }
                }
            }
            #endif
        }
    }
}
