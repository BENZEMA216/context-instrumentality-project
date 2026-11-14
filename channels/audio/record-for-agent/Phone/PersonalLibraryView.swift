import RecordingCore
import SwiftUI

struct PersonalLibraryView: View {
    @EnvironmentObject private var store: PhoneStore
    @ObservedObject var library: PersonalLibraryStore

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("你的录音，由你决定如何使用").font(.title2.weight(.semibold))
                    Text("原录音保留在手机。以下首批录音用于本机转写和首批备份，不会改变同步首页中 Google Drive 或 iCloud Drive 的范围。")
                        .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                    if let snapshot = library.snapshot {
                        Label("首批已确定 \(snapshot.manifests.count) 段", systemImage: "checkmark.circle")
                            .font(.subheadline.weight(.semibold))
                        Text("之后新增的录音不会自动加入这批授权。")
                            .font(.caption).foregroundStyle(RecordDesign.secondary)
                    } else {
                        Text("当前手机保存了 \(store.manifests.count) 段。先确定这次处理的范围。")
                            .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                        Button("将当前 \(store.manifests.count) 段设为首批录音") {
                            library.captureInitialSnapshot(store.manifests)
                        }
                        .buttonStyle(RecordPrimaryButtonStyle())
                        .disabled(store.manifests.isEmpty || library.isBusy)
                    }
                }.fixedSize(horizontal: false, vertical: true).recordCard().recordRow()
            }

            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("本机转写").font(.headline)
                        Spacer()
                        Text("\(library.transcriptCount) 段可用").font(.subheadline).monospacedDigit()
                    }
                    Text(library.modelMessage).font(.subheadline).foregroundStyle(RecordDesign.secondary)
                    Picker("录音语言", selection: $library.localeIdentifier) {
                        Text("中文（普通话）").tag("zh-CN")
                        Text("English").tag("en-US")
                    }.disabled(library.isBusy)
                    if case .notInstalled = library.modelStatus {
                        Button("下载本机语言模型") { library.prepareModel() }
                            .buttonStyle(RecordPrimaryButtonStyle()).disabled(library.isBusy)
                    }
                    Button("转写首批录音") { library.transcribeInitialSnapshot() }
                        .buttonStyle(RecordPrimaryButtonStyle())
                        .disabled(library.snapshot == nil || !library.modelReady || library.isBusy)
                    Text("已完成的文字会保留；未识别出语音的片段会单独提示。")
                        .font(.caption).foregroundStyle(RecordDesign.secondary)
                }.fixedSize(horizontal: false, vertical: true).recordCard().recordRow()
            }

            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text("首批 iCloud 备份").font(.headline)
                    Text(library.cloudStatus.message).font(.subheadline).foregroundStyle(RecordDesign.secondary)
                    Text("原录音 \(library.cloudStatus.savedAudioCount) 段 · 转写 \(library.cloudStatus.savedTranscriptCount) 段已保存")
                        .font(.subheadline).monospacedDigit()
                    Button("保存首批录音与转写备份") { library.saveToCloud() }
                        .buttonStyle(RecordPrimaryButtonStyle())
                        .disabled(!library.cloudStatus.canUpload || library.isBusy)
                    Button("检查 iCloud 账户") { library.checkCloudAccount() }
                        .disabled(library.isBusy)
                    Text("只处理已确定的首批范围。持续文件同步请使用同步首页的 iCloud Drive；备份失败不会删除手机上的原录音。")
                        .font(.caption).foregroundStyle(RecordDesign.secondary)
                    ForEach(Array(library.cloudStatus.errors.enumerated()), id: \.offset) { _, error in
                        Text(error).font(.caption).foregroundStyle(RecordDesign.accent)
                    }
                }.fixedSize(horizontal: false, vertical: true).recordCard().recordRow()
            }

            Section {
                NavigationLink {
                    AgentConnectionView(store: library.agentConnections)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("授权 Agent 连接").font(.headline)
                        Text("连接 Codex、WorkBuddy，选择可读取的录音并管理授权。")
                            .font(.caption).foregroundStyle(RecordDesign.secondary)
                    }.recordCard()
                }.recordRow()
                NavigationLink { AgentExportView() } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("导出给本地 Agent").font(.headline)
                        Text("选择片段，把原录音与已有转写带到 Mac。")
                            .font(.caption).foregroundStyle(RecordDesign.secondary)
                    }.recordCard()
                }.recordRow()
            }

            if let snapshot = library.snapshot {
                Section("首批录音") {
                    ForEach(snapshot.manifests) { manifest in
                        if let transcript = library.transcripts[manifest.id] {
                            NavigationLink {
                                TranscriptDetailView(manifest: manifest, transcript: transcript)
                            } label: {
                                row(manifest, status: "转写可用", symbol: "text.alignleft")
                            }.recordRow()
                        } else {
                            row(manifest, status: library.issues[manifest.id] ?? "尚无转写文字",
                                symbol: library.issues[manifest.id] == nil ? "waveform" : "exclamationmark.circle")
                                .recordRow()
                        }
                    }
                }
            }
            if !library.activity.isEmpty || library.error != nil {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        if library.isBusy { ProgressView() }
                        if !library.activity.isEmpty { Text(library.activity).font(.subheadline) }
                        if let error = library.error { Text(error).foregroundStyle(RecordDesign.accent).font(.subheadline) }
                        if library.isBusy { Button("停止当前操作") { library.cancel() } }
                    }.fixedSize(horizontal: false, vertical: true).recordCard().recordRow()
                }
            }
        }
        .recordListAppearance()
        .navigationTitle("个人录音库")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: library.localeIdentifier) { if !library.isBusy { await library.refresh() } }
    }

    private func row(_ manifest: SegmentManifest, status: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(manifest.startedAt.formatted(date: .abbreviated, time: .standard)).font(.subheadline.weight(.semibold))
                Text("片段 \(manifest.sequence + 1) · \(Int(manifest.duration.rounded())) 秒 · \(status)")
                    .font(.caption).foregroundStyle(RecordDesign.secondary)
            }.fixedSize(horizontal: false, vertical: true)
        }.frame(minHeight: 44)
    }
}

struct RecordingTranscriptionView: View {
    @EnvironmentObject private var store: PhoneStore
    @ObservedObject var library: PersonalLibraryStore
    let groupID: UUID

    private struct LoadKey: Equatable {
        let manifests: [SegmentManifest]
        let isBusy: Bool
    }

    @State private var loaded: (manifests: [SegmentManifest], text: TranscriptRepository.AvailableTranscripts)?
    @State private var requestedModel = false

    private var manifests: [SegmentManifest] {
        store.manifests.filter { $0.recordingGroupID == groupID && store.receivedSegmentIDs.contains($0.id) }
            .sorted { $0.recordingPartIndex < $1.recordingPartIndex }
    }

    private var recordingResult: PersonalLibraryStore.RecordingTranscription? {
        guard library.recordingTranscription?.groupID == groupID else { return nil }
        return library.recordingTranscription
    }

    var body: some View {
        let selection = manifests
        let current = loaded?.manifests == selection ? loaded?.text : nil
        let active = recordingResult != nil && recordingResult?.failures == nil
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text("只转写这条录音已收到的音频。")
                        .font(.subheadline)
                    Picker("录音语言", selection: $library.localeIdentifier) {
                        Text("中文（普通话）").tag("zh-CN")
                        Text("English").tag("en-US")
                    }
                    .disabled(library.isBusy)
                    Text(library.modelMessage).font(.caption).foregroundStyle(RecordDesign.secondary)
                    if case .notInstalled = library.modelStatus {
                        Button("下载本机语言模型") {
                            requestedModel = true
                            library.prepareModel()
                        }
                        .buttonStyle(RecordSecondaryButtonStyle()).disabled(library.isBusy)
                    }
                    if requestedModel, let error = library.error {
                        Text(error).font(.caption).foregroundStyle(RecordDesign.accent)
                    }
                    if active {
                        ProgressView("正在本机转写")
                        Button("停止转写") { library.cancelRecordingTranscription(for: groupID) }
                            .buttonStyle(RecordSecondaryButtonStyle())
                    } else if current?.transcripts.count != selection.count {
                        Button("转写这条录音") { library.transcribeRecording(selection, groupID: groupID) }
                            .buttonStyle(RecordPrimaryButtonStyle())
                            .disabled(!library.modelReady || library.isBusy || current == nil || selection.isEmpty)
                            .accessibilityIdentifier("transcribe-recording")
                    }
                }.recordCard().recordRow()
            }
            if let current {
                let failures = recordingResult?.failures ?? [:]
                ForEach(selection) { manifest in
                    if let transcript = current.transcripts[manifest.id] {
                        Text(transcript.text).textSelection(.enabled)
                            .accessibilityIdentifier("recording-transcript-text")
                            .recordCard().recordRow()
                    } else if let error = current.issues[manifest.id] ?? failures[manifest.id] {
                        Text(error).font(.subheadline).foregroundStyle(RecordDesign.accent).recordRow()
                    }
                }
            }
        }
        .recordListAppearance()
        .navigationTitle("转写文字")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: library.localeIdentifier) { await library.refreshTranscriptionModel() }
        .task(id: LoadKey(manifests: selection, isBusy: library.isBusy)) {
            let text = await library.availableTranscripts(for: selection)
            guard !Task.isCancelled else { return }
            loaded = (selection, text)
        }
    }
}

private struct TranscriptDetailView: View {
    let manifest: SegmentManifest
    let transcript: SegmentTranscript

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(manifest.startedAt.formatted(date: .abbreviated, time: .standard))
                    .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                Text(transcript.text).font(.body).textSelection(.enabled)
                Text("自动转写可能有误，请结合原录音核对。")
                    .font(.caption).foregroundStyle(RecordDesign.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
        }.background(RecordDesign.background).foregroundStyle(RecordDesign.ink)
            .navigationTitle("转写文字").navigationBarTitleDisplayMode(.inline)
    }
}
