import SwiftUI
import JasmineMobileCore

struct ApprovalsTabView: View {
    @Bindable var store: AppStoreModel

    var body: some View {
        NavigationStack {
            List {
                if store.approvals.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "没有待审批操作",
                            systemImage: "checkmark.seal.fill",
                            description: Text("当 Bot 提议写入新规则、修改长期记忆或请求高风险动作时，会在这里弹出三键审批卡。")
                        )
                        .padding(.vertical, 32)
                    }
                } else {
                    Section("待你把关 (\(store.approvals.count))") {
                        ForEach(store.approvals) { item in
                            ApprovalCardRow(item: item) { mode in
                                Task { await store.decideApproval(item, mode: mode) }
                            }
                        }
                    }
                }
            }
            .navigationTitle("安全审批")
            .refreshable {
                await store.refreshAll()
            }
        }
    }
}

private struct ApprovalCardRow: View {
    let item: ApprovalItem
    let onDecide: (ApprovalDecisionMode) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(item.kind.uppercased(), systemImage: "exclamationmark.shield.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.orange)
                if let proj = item.projectName, !proj.isEmpty {
                    Text("· \(proj)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Text(item.title)
                .font(.headline)

            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(6)
            }

            // Grok-Bot 3-Action Approval Bar: 允许一次 / 总是允许 / 拒绝
            HStack(spacing: 8) {
                Button {
                    onDecide(.allowOnce)
                } label: {
                    Text("允许一次")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    onDecide(.allowAlways)
                } label: {
                    Text("总是允许")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button(role: .destructive) {
                    onDecide(.reject)
                } label: {
                    Text("拒绝")
                        .font(.caption.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .padding(.vertical, 6)
    }
}
