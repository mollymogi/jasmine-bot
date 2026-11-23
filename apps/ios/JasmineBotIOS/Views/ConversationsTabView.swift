import SwiftUI
import JasmineMobileCore

struct ConversationsTabView: View {
    @Bindable var store: AppStoreModel
    @State private var path: [ChatRoomSummary] = []
    @State private var creatingBot = false
    @State private var searchText = ""
    @State private var filterKind: RoomFilter = .all

    enum RoomFilter: String, CaseIterable {
        case all = "全部"
        case running = "运行中"
        case direct = "单聊 Bot"
        case group = "协作群聊"
    }

    private var filteredRooms: [ChatRoomSummary] {
        store.rooms.filter { room in
            let matchesSearch = searchText.isEmpty
                || room.title.localizedCaseInsensitiveContains(searchText)
                || (room.project ?? "").localizedCaseInsensitiveContains(searchText)
            guard matchesSearch else { return false }
            switch filterKind {
            case .all: return true
            case .running: return room.busy == true
            case .direct: return room.isDirectBot
            case .group: return !room.isDirectBot
            }
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(RoomFilter.allCases, id: \.self) { f in
                            Button {
                                filterKind = f
                            } label: {
                                Text(f.rawValue)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        filterKind == f ? Color.accentColor : Color.secondary.opacity(0.12),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(filterKind == f ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }

                if let err = store.connectionError {
                    HStack {
                        Image(systemName: "wifi.exclamationmark")
                        Text(err).lineLimit(2)
                        Spacer()
                        Button("重连") {
                            Task { await store.reraceRoutesSilently(); await store.refreshAll() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Color.orange.opacity(0.1))
                }

                List(filteredRooms) { room in
                    NavigationLink(value: room) {
                        RoomRowView(room: room)
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await store.refreshAll()
                }
                .overlay {
                    if filteredRooms.isEmpty {
                        ContentUnavailableView(
                            "暂无匹配的会话",
                            systemImage: "bubble.left.and.text.bubble.right",
                            description: Text("调整筛选条件，或点右上角的加号创建 Bot")
                        )
                    }
                }
            }
            .navigationTitle("Jasmine Bot")
            .searchable(text: $searchText, prompt: "搜索 Bot、群聊或项目目录")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("创建 Bot", systemImage: "plus") { creatingBot = true }
                }
                ToolbarItem(placement: .topBarLeading) {
                    RouteStatusPill(outcome: store.activeRoute) {
                        Task { await store.reraceRoutesSilently() }
                    }
                }
            }
            .sheet(isPresented: $creatingBot) {
                CreateBotView(client: store.client) { room in
                    creatingBot = false
                    path.append(room)
                    Task { await store.refreshAll() }
                }
            }
            .navigationDestination(for: ChatRoomSummary.self) { room in
                ChatRoomDetailView(store: store, roomSummary: room)
            }
        }
    }
}

private struct RoomRowView: View {
    let room: ChatRoomSummary

    private var leadBrand: AgentBrand {
        if let first = room.members?.first {
            return first.brand
        }
        return .generic
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                BrandAvatarView(brand: leadBrand, size: 42)
                if room.busy == true {
                    Circle()
                        .fill(.green)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(.background, lineWidth: 2))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(room.title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    if !room.isDirectBot {
                        Text("\(room.memberCount ?? room.members?.count ?? 0) 成员")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                    }
                    Spacer()
                    if room.busy == true {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("执行中")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                    }
                }

                if room.isDirectBot, let bot = room.members?.first, let cli = bot.cli {
                    Label("\(bot.executionNodeLabel ?? bot.executionNodeId ?? bot.workerNodeId ?? "数据主机") · \(cli)",
                          systemImage: "terminal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let proj = room.project, !proj.isEmpty {
                    Text((proj as NSString).lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
