import SwiftUI
import JasmineMobileCore

struct HostStatusTabView: View {
    @Bindable var store: AppStoreModel
    @State private var tunnelUrlDraft = ""

    var body: some View {
        NavigationStack {
            List {
                Section("多通道同步选路 (免 VPN 优先)") {
                    if let active = store.activeRoute {
                        HStack {
                            Label(active.endpoint.kind.displayTitle, systemImage: "bolt.horizontal.fill")
                                .font(.subheadline.weight(.semibold))
                            Spacer()
                            Text("\(active.latencyMs) ms")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.green)
                        }
                        Text(active.endpoint.origin)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }

                    if let routes = store.credentials?.routes {
                        ForEach(routes) { r in
                            HStack {
                                Text(r.label)
                                    .font(.caption.weight(.medium))
                                Spacer()
                                Text(r.origin)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }

                    HStack {
                        TextField("新增/更新公网 HTTPS 隧道域名", text: $tunnelUrlDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.caption.monospaced())
                        Button("保存并测速") {
                            Task {
                                await store.addOrUpdateTunnelRoute(tunnelUrlDraft)
                                tunnelUrlDraft = ""
                            }
                        }
                        .disabled(tunnelUrlDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                    }

                    Button {
                        Task { await store.reraceRoutesSilently() }
                    } label: {
                        Label("立即重新测速选路", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                Section("模型订阅周额度 (Magpie)") {
                    if store.quotas.isEmpty {
                        Text("暂无额度统计数据")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.quotas) { q in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(q.label)
                                        .font(.subheadline.weight(.medium))
                                    Spacer()
                                    if let pct = q.remainingPercent {
                                        Text("剩余 \(Int(pct))%")
                                            .font(.caption.monospacedDigit().weight(.semibold))
                                            .foregroundStyle(pct <= 15 ? .red : .secondary)
                                    } else if let err = q.error {
                                        Text(err)
                                            .font(.caption2)
                                            .foregroundStyle(.orange)
                                    }
                                }
                                if let pct = q.remainingPercent {
                                    ProgressView(value: max(0, min(100, pct)), total: 100)
                                        .tint(pct <= 15 ? Color.red : (pct <= 35 ? Color.orange : Color.accentColor))
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("在线电脑节点 (Primary & Followers)") {
                    HStack {
                        Image(systemName: "macmini.fill")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading) {
                            Text(store.hostSummary?.hostname ?? store.credentials?.hostLabel ?? "主控 Mac")
                                .font(.subheadline.weight(.semibold))
                            Text("Primary 主控中枢 · 记忆与会话唯一真相源")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("在线")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.green)
                    }

                    ForEach(store.workerNodes) { node in
                        HStack {
                            Image(systemName: "desktopcomputer")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading) {
                                Text(node.label)
                                    .font(.subheadline.weight(.medium))
                                if let cwd = node.defaultCwd {
                                    Text(cwd)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            Spacer()
                            Text(node.online == true ? "在线" : "离线")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(node.online == true ? .green : .secondary)
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task { await store.signOut() }
                    } label: {
                        Label("断开此 iPhone 配对", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle("主机与额度")
            .refreshable {
                await store.refreshAll()
            }
        }
    }
}
