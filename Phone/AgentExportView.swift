import RecordingCore
import SwiftUI

struct AgentExportView: View {
    @EnvironmentObject private var store: PhoneStore
    @Environment(\.sizeCategory) private var sizeCategory
    private var selectedIDs: Set<UUID> { store.agentSelectedIDs }

    private var selected: [SegmentManifest] { store.manifests.filter { selectedIDs.contains($0.id) } }
    private var byteCount: Int64 { selected.reduce(0) { $0 + $1.byteCount } }
    private var duration: TimeInterval { selected.reduce(0) { $0 + $1.duration } }
    private var exceedsLimit: Bool {
        selected.count > AgentExportBuilder.maximumSegments || byteCount > AgentExportBuilder.maximumBytes
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Image(systemName: "sparkles").font(.title2).accessibilityHidden(true)
                    Text("把这次录音交给 Agent").font(.title2.weight(.semibold))
                    Text("选择片段，生成一个导出包，再通过 AirDrop 或“存储到文件”带到 Mac。在 Mac 导入后，可供 Codex / WorkBuddy 读取。")
                        .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                    Text("包含所选原始音频、时间信息和已经完成的转写。尚未转写的片段只提供音频。分享后，接收方可以访问包内全部内容。")
                        .font(.caption).foregroundStyle(RecordDesign.secondary)
                }.fixedSize(horizontal: false, vertical: true).recordCard().recordRow()
            }
            Section {
                if store.manifests.isEmpty {
                    Text("手机收到录音后，就可以在这里选择片段。")
                        .font(.subheadline).foregroundStyle(RecordDesign.secondary).recordCard().recordRow()
                }
                ForEach(store.manifests) { manifest in
                    Button {
                        store.toggleAgentSelection(manifest.id)
                    } label: {
                        HStack(alignment: .center, spacing: 14) {
                            Image(systemName: selectedIDs.contains(manifest.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title2).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(manifest.startedAt.formatted(date: .abbreviated, time: .standard))
                                    .font(.subheadline.weight(.semibold))
                                Text("片段 \(manifest.sequence + 1) · \(Int(manifest.duration.rounded())) 秒 · \(ByteCountFormatter.string(fromByteCount: manifest.byteCount, countStyle: .file))")
                                    .font(.caption).foregroundStyle(RecordDesign.secondary)
                            }.fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }.frame(minHeight: 48)
                    }
                    .buttonStyle(.plain)
                    .disabled(store.isPreparingAgentExport)
                    .accessibilityValue(selectedIDs.contains(manifest.id) ? "已选择" : "未选择")
                    .accessibilityHint("切换是否包含在导出包中")
                    .recordRow()
                }
            } header: {
                Text("选择录音").font(.subheadline.weight(.semibold))
            }
            if sizeCategory.isAccessibilityCategory {
                Section {
                    exportControls.recordCard().recordRow()
                }
            }
        }
        .recordListAppearance()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !sizeCategory.isAccessibilityCategory {
                exportControls
                    .padding(.horizontal, 24).padding(.vertical, 14)
                    .background(RecordDesign.surface)
            }
        }
        .navigationTitle("交给 Agent")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("已选 \(selected.count) 段 · \(Int(duration / 60)) 分 \(Int(duration) % 60) 秒")
                .font(.headline).monospacedDigit()
            Text("原始音频 \(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)) · 最多 500 段 / 500 MB")
                .font(.caption).foregroundStyle(RecordDesign.secondary)
            if exceedsLimit {
                Text("选择超过单次上限，请减少片段后再生成。")
                    .font(.caption).foregroundStyle(RecordDesign.accent)
            }
            if let error = store.agentExportError {
                Text(error).font(.subheadline).foregroundStyle(RecordDesign.accent)
            }
            if let url = store.agentExportURL {
                Label("导出包已生成", systemImage: "checkmark.circle")
                    .font(.subheadline.weight(.semibold))
                ShareLink(item: url) {
                    Label("分享导出包到 Mac", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }.buttonStyle(RecordPrimaryButtonStyle())
                Text("导出包已就绪。Mac 导入和 Agent 连接状态需在电脑端确认。")
                    .font(.caption).foregroundStyle(RecordDesign.secondary)
            } else {
                Button { store.prepareAgentExport() } label: {
                    HStack(spacing: 10) {
                        if store.isPreparingAgentExport { ProgressView().tint(RecordDesign.background) }
                        Text(store.isPreparingAgentExport ? "正在准备所选录音" : "生成导出包")
                    }.frame(maxWidth: .infinity)
                }
                .buttonStyle(RecordPrimaryButtonStyle())
                .disabled(selected.isEmpty || exceedsLimit || store.isPreparingAgentExport)
            }
        }
        .foregroundStyle(RecordDesign.ink)
        .lineLimit(nil)
        .fixedSize(horizontal: false, vertical: true)
    }
}
