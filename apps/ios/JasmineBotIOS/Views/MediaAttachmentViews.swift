import SwiftUI
import AVKit
import AVFoundation
import JasmineMobileCore

#if os(iOS)
import UIKit
#endif

struct MessageMediaStripView: View {
    let store: AppStoreModel
    let roomId: String
    let attachments: [RoomMediaAttachment]

    @State private var selectedImageAttachment: RoomMediaAttachment?
    @State private var selectedVideoAttachment: RoomMediaAttachment?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(attachments) { item in
                switch item.kind {
                case .image:
                    AuthenticatedImageThumbnailCard(store: store, roomId: roomId, item: item) {
                        selectedImageAttachment = item
                    }
                case .video, .audio:
                    Button {
                        selectedVideoAttachment = item
                    } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 38, height: 38)
                                Image(systemName: item.kind == .video ? "play.fill" : "waveform")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(item.kind == .video ? "点击在线播放原片 (支持拖动进度 / 全屏)" : "点击播放音频")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(10)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                case .file:
                    EmptyView()
                }
            }
        }
        .sheet(item: $selectedImageAttachment) { imgItem in
            FullScreenImageSheet(store: store, roomId: roomId, item: imgItem)
        }
        .sheet(item: $selectedVideoAttachment) { vidItem in
            FullScreenVideoPlayerSheet(store: store, roomId: roomId, item: vidItem)
        }
    }
}

private struct AuthenticatedImageThumbnailCard: View {
    let store: AppStoreModel
    let roomId: String
    let item: RoomMediaAttachment
    let onTap: () -> Void

    @State private var imageData: Data?
    @State private var failed = false

    var body: some View {
        Button(action: onTap) {
            Group {
                #if os(iOS)
                if let imageData, let uiImg = UIImage(data: imageData) {
                    Image(uiImage: uiImg)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: 240, maxHeight: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                } else if failed {
                    fallbackLabel("图片加载失败：\(item.name)")
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(item.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: 200, height: 96)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                }
                #else
                fallbackLabel(item.name)
                #endif
            }
        }
        .buttonStyle(.plain)
        .task(id: item.path) {
            guard imageData == nil else { return }
            do {
                imageData = try await store.client.fetchRoomMediaData(
                    roomId: roomId,
                    filePath: item.path,
                    thumbnail: true,
                    maxWidth: 720
                )
            } catch {
                failed = true
            }
        }
    }

    private func fallbackLabel(_ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "photo")
            Text(title).font(.caption).lineLimit(1)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct FullScreenImageSheet: View {
    let store: AppStoreModel
    let roomId: String
    let item: RoomMediaAttachment

    @Environment(\.dismiss) private var dismiss
    @State private var fullData: Data?
    @State private var errorText: String?
    @State private var scale: CGFloat = 1.0

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                #if os(iOS)
                if let fullData, let uiImg = UIImage(data: fullData) {
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        Image(uiImage: uiImg)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity)
                            .scaleEffect(scale)
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { val in scale = max(1.0, min(4.0, val)) }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation { scale = scale > 1.0 ? 1.0 : 2.2 }
                            }
                    }
                } else if let errorText {
                    Text(errorText)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding()
                } else {
                    ProgressView("正在加载原图…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
                #endif
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .task {
            do {
                fullData = try await store.client.fetchRoomMediaData(
                    roomId: roomId,
                    filePath: item.path,
                    thumbnail: false
                )
            } catch {
                errorText = "加载失败：\(error.localizedDescription)"
            }
        }
    }
}

private struct FullScreenVideoPlayerSheet: View {
    let store: AppStoreModel
    let roomId: String
    let item: RoomMediaAttachment

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                } else if let errorText {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(errorText)
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                } else {
                    ProgressView("正在连接主机视频流…")
                        .tint(.white)
                        .foregroundStyle(.white)
                }
            }
            .navigationTitle(item.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        player?.pause()
                        dismiss()
                    }
                }
            }
        }
        .task {
            do {
                #if os(iOS)
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try? AVAudioSession.sharedInstance().setActive(true)
                #endif
                let info = try await store.client.resolveRoomMediaStreamInfo(roomId: roomId, filePath: item.path)
                let asset = AVURLAsset(
                    url: info.url,
                    options: ["AVURLAssetHTTPHeaderFieldsKey": info.headers]
                )
                let avPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                self.player = avPlayer
                avPlayer.play()
            } catch {
                self.errorText = "无法播放：\(error.localizedDescription)"
            }
        }
        .onDisappear {
            player?.pause()
        }
    }
}
