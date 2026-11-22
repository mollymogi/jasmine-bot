import SwiftUI
import JasmineMobileCore

public struct BrandAvatarView: View {
    public let brand: AgentBrand
    public var size: CGFloat = 34

    public init(brand: AgentBrand, size: CGFloat = 34) {
        self.brand = brand
        self.size = size
    }

    private var tintColor: Color {
        switch brand {
        case .claude: return Color(red: 0.85, green: 0.47, blue: 0.34)
        case .openai: return Color(red: 0.09, green: 0.64, blue: 0.50)
        case .grok: return Color(red: 0.14, green: 0.15, blue: 0.18)
        case .gemini: return Color(red: 0.26, green: 0.52, blue: 0.96)
        case .deepseek: return Color(red: 0.30, green: 0.42, blue: 0.95)
        case .glm: return Color(red: 0.22, green: 0.62, blue: 0.86)
        case .generic: return Color(red: 0.45, green: 0.42, blue: 0.56)
        }
    }

    public var body: some View {
        ZStack {
            Circle()
                .fill(tintColor.gradient)
                .frame(width: size, height: size)
            Text(brand.shortBadge)
                .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
    }
}

public struct RouteStatusPill: View {
    public let outcome: RouteProbeOutcome?
    public let onTap: () -> Void

    public var body: some View {
        Button(action: onTap) {
            HStack(spacing: 5) {
                Circle()
                    .fill(outcome != nil ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                Text(labelText)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var labelText: String {
        guard let outcome else { return "选路重连中…" }
        switch outcome.endpoint.kind {
        case .lan: return "局域网 · \(outcome.latencyMs)ms"
        case .tunnel: return "公网隧道 · \(outcome.latencyMs)ms"
        case .tailscale, .magicdns: return "Tailscale · \(outcome.latencyMs)ms"
        case .custom: return "直连 · \(outcome.latencyMs)ms"
        }
    }
}

struct MainTabView: View {
    @Bindable var store: AppStoreModel

    var body: some View {
        TabView(selection: $store.selectedTab) {
            Tab("对话", systemImage: "bubble.left.and.bubble.right.fill", value: AppStoreModel.TabSelection.chats) {
                ConversationsTabView(store: store)
            }

            Tab("审批", systemImage: "checkmark.shield.fill", value: AppStoreModel.TabSelection.approvals) {
                ApprovalsTabView(store: store)
            }
            .badge(store.approvals.count)

            Tab("语音", systemImage: "waveform.circle.fill", value: AppStoreModel.TabSelection.voice) {
                VoiceConsoleView(store: store)
            }

            Tab("主机", systemImage: "desktopcomputer", value: AppStoreModel.TabSelection.host) {
                HostStatusTabView(store: store)
            }
        }
    }
}
