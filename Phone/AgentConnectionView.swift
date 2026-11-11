import AuthenticationServices
import SwiftUI
import UIKit

struct AgentConnectionView: View {
    @ObservedObject var store: AgentConnectionStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var copiedURL = false
    @State private var revokeTarget: AgentConnection?
    @State private var showSignOut = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text("让 Agent 读取你选的录音").font(.title2.weight(.semibold))
                    Text("先同步转写，再核对接收方并批准。原音频留在你的 iCloud 私有库，Agent 服务只接收录音信息与转写文字。")
                        .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                    Label(store.statusTitle, systemImage: statusSymbol).font(.headline)
                    Text(store.statusMessage).font(.subheadline).foregroundStyle(RecordDesign.secondary)
                }.fixedSize(horizontal: false, vertical: true).recordCard().recordRow()
            }

            if store.isConfigured {
                signInSection
                cacheSection
                connectSection
                if store.pendingAuthorization != nil { approvalSection }
                connectionsSection
            }

            if !store.activity.isEmpty || store.error != nil {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        if store.isWorking { ProgressView().accessibilityLabel("正在处理") }
                        if !store.activity.isEmpty { Text(store.activity).font(.subheadline) }
                        if let error = store.error {
                            Text(error).font(.subheadline).foregroundStyle(RecordDesign.accent)
                        }
                        if store.isBusy {
                            Button("停止当前操作") { store.cancel() }
                                .buttonStyle(RecordSecondaryButtonStyle())
                        }
                    }.fixedSize(horizontal: false, vertical: true).recordCard().recordRow()
                }
            }
        }
        .recordListAppearance()
        .navigationTitle("Agent 连接")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refreshLocalState() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refreshLocalState() } }
        }
        .confirmationDialog("撤销这项 Agent 授权？", isPresented: Binding(
            get: { revokeTarget != nil }, set: { if !$0 { revokeTarget = nil } }), titleVisibility: .visible) {
            if let connection = revokeTarget {
                Button("撤销授权", role: .destructive) { store.revoke(connection); revokeTarget = nil }
            }
            Button("取消", role: .cancel) { revokeTarget = nil }
        } message: {
            Text("撤销后会拒绝后续读取。Agent 已读取的内容无法远程收回，手机和 iCloud 中的录音仍保留。")
        }
        .confirmationDialog("退出这台手机的登录？", isPresented: $showSignOut, titleVisibility: .visible) {
            Button("退出本机登录", role: .destructive) { store.signOut() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("退出不会自动撤销 Agent 已获得的独立授权。如需停止 Agent 读取，请先在授权列表中逐项撤销。")
        }
    }

    private var statusSymbol: String {
        if !store.isConfigured { return "server.rack" }
        if !store.hasSavedSignIn { return "person.crop.circle" }
        if store.activeConnectionCount > 0 { return "checkmark.shield" }
        if store.cachedCount > 0 { return "text.badge.checkmark" }
        return "arrow.triangle.2.circlepath"
    }

    private var signInSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Text("1 · 使用 Apple 登录").font(.headline)
                if store.hasSavedSignIn {
                    Text(store.serverSessionConfirmed ? "本机登录已确认。" : "已保存本机登录凭据，服务端状态尚未核对。")
                        .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                    Button("退出本机登录") { showSignOut = true }
                        .buttonStyle(RecordSecondaryButtonStyle()).disabled(store.isWorking)
                    Text("退出登录不会自动撤销 Agent 授权。")
                        .font(.caption).foregroundStyle(RecordDesign.secondary)
                } else {
                    Text("请先在个人录音库把首批录音保存到 iCloud。登录将绑定这批录音原来的 iCloud 账户。")
                        .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                    if let challenge = store.challenge {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            if challenge.expiresAt > context.date {
                                VStack(alignment: .leading, spacing: 10) {
                                    SignInWithAppleButton(.signIn,
                                        onRequest: store.configureAppleRequest,
                                        onCompletion: store.completeAppleSignIn)
                                        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                                        .frame(minHeight: 54, maxHeight: 54)
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                        .disabled(store.isWorking)
                                    Text("登录准备有效至 \(challenge.expiresAt.formatted(date: .omitted, time: .shortened))。")
                                        .font(.caption).foregroundStyle(RecordDesign.secondary)
                                }
                            } else {
                                Text("登录准备已过期，请重新准备。")
                                    .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                            }
                        }
                    }
                    Button(store.challenge == nil ? "准备 Apple 登录" : "重新准备 Apple 登录") {
                        store.prepareAppleLogin()
                    }.buttonStyle(RecordSecondaryButtonStyle()).disabled(store.isWorking)
                    Text("无需向 Agent 提供 Apple 密码，也不会申请姓名或邮箱。")
                        .font(.caption).foregroundStyle(RecordDesign.secondary)
                }
            }.fixedSize(horizontal: false, vertical: true).recordCard().recordRow()
        }
    }

    private var cacheSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Text("2 · 同步首批转写").font(.headline)
                Text("可同步 \(store.eligibleCount) 段 · 本次确认缓存 \(store.cachedCount) 段")
                    .font(.subheadline).monospacedDigit()
                Text("只同步首批范围内，已经保存到 iCloud 且转写有效的片段。之后新增的录音不会自动加入。")
                    .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                Button("同步可用转写") { store.cacheTranscripts() }
                    .buttonStyle(RecordPrimaryButtonStyle())
                    .disabled(!store.hasSavedSignIn || store.isWorking || store.eligibleCount == 0)
                Text("重新打开 App 后，需要再次同步以确认缓存；重复同步不会新增重复录音。")
                    .font(.caption).foregroundStyle(RecordDesign.secondary)
                if store.unavailableTranscriptCount > 0 {
                    Text("有 \(store.unavailableTranscriptCount) 段转写未通过核对，未纳入同步。请回到个人录音库检查。")
                        .font(.caption).foregroundStyle(RecordDesign.accent)
                }
            }.fixedSize(horizontal: false, vertical: true).recordCard().recordRow()
        }
    }

    private var connectSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Text("3 · 从 Agent 发起连接").font(.headline)
                Text("在支持远程 MCP 与 OAuth 的 Agent 中添加下方地址。打开其授权网页，把网页上的代码填到这里。")
                    .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                if let url = store.mcpURL {
                    Text(url.absoluteString).font(.callout.monospaced())
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Button(copiedURL ? "地址已复制" : "复制 MCP 地址") {
                        UIPasteboard.general.string = url.absoluteString
                        copiedURL = true
                    }.buttonStyle(RecordSecondaryButtonStyle())
                }
                Text("Codex、WorkBuddy 等客户端需在各自界面中添加连接；是否支持该授权方式以客户端实际能力为准。")
                    .font(.caption).foregroundStyle(RecordDesign.secondary)
                TextField("网页上的授权码", text: $store.authorizationCode)
                    .font(.title3.monospaced())
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .textContentType(.oneTimeCode)
                    .submitLabel(.go)
                    .padding(14)
                    .background(RecordDesign.inset, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel("网页上的授权码")
                    .disabled(!store.hasSavedSignIn || store.isWorking)
                    .onSubmit { store.lookupAuthorization() }
                Button("查看接收方与录音范围") { store.lookupAuthorization() }
                    .buttonStyle(RecordPrimaryButtonStyle())
                    .disabled(!store.hasSavedSignIn || store.isWorking || store.cachedCount == 0 || store.authorizationCode.isEmpty)
            }.fixedSize(horizontal: false, vertical: true).recordCard().recordRow()
        }
    }

    private var approvalSection: some View {
        Section {
            if let request = store.pendingAuthorization {
                VStack(alignment: .leading, spacing: 16) {
                    Text("核对这次授权").font(.title3.weight(.semibold))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(request.clientName).font(.headline)
                        Text("客户端自行登记的名称，未经身份认证。")
                            .font(.caption).foregroundStyle(RecordDesign.secondary)
                    }
                    identityLine("客户端域名", value: request.clientDomain ?? "未提供")
                    identityLine("授权返回位置", value: request.redirectHost)
                    if request.redirectIsLoopback {
                        Text("授权将返回你电脑上的本地应用。仅在你刚从该应用发起连接时批准。")
                            .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                    }
                    Divider()
                    Text("申请读取").font(.subheadline.weight(.semibold))
                    ForEach(request.requestedScopes, id: \.rawValue) { scope in
                        Label(scope.title, systemImage: scope == .transcripts ? "text.alignleft" : "clock")
                            .font(.subheadline)
                    }
                    Text("不提供原音频，不允许修改或删除录音。")
                        .font(.caption).foregroundStyle(RecordDesign.secondary)
                    Divider()
                    Text("本次选择 \(store.selectedRecordingIDs.count) 段").font(.headline).monospacedDigit()
                    ForEach(store.authorizationRecordings) { choice in
                        Toggle(isOn: Binding(
                            get: { store.selectedRecordingIDs.contains(choice.id) },
                            set: { store.setSelected(choice.id, selected: $0) })) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(choice.manifest.startedAt.formatted(date: .abbreviated, time: .standard))
                                    .font(.subheadline.weight(.semibold))
                                Text("片段 \(choice.manifest.sequence + 1) · \(Int(choice.manifest.duration.rounded())) 秒")
                                    .font(.caption).foregroundStyle(RecordDesign.secondary)
                            }
                        }.disabled(store.isWorking)
                    }
                    Text("之后新增的录音不会自动授权。你可以随时撤销后续读取权限，但无法远程收回 Agent 已读取的内容。")
                        .font(.caption).foregroundStyle(RecordDesign.secondary)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        VStack(alignment: .leading, spacing: 10) {
                            if request.expiresAt <= context.date {
                                Text("授权请求已过期，请从 Agent 重新发起。")
                                    .font(.subheadline).foregroundStyle(RecordDesign.accent)
                            }
                            Button("批准读取这 \(store.selectedRecordingIDs.count) 段") { store.approveAuthorization() }
                                .buttonStyle(RecordPrimaryButtonStyle())
                                .disabled(!store.canApprove || request.expiresAt <= context.date)
                        }
                    }
                    Button("暂不授权") { store.dismissAuthorization() }
                        .buttonStyle(RecordSecondaryButtonStyle()).disabled(store.isWorking)
                }.fixedSize(horizontal: false, vertical: true).recordCard().recordRow()
            }
        }
    }

    private var connectionsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 14) {
                Text("管理 Agent 授权").font(.headline)
                if let date = store.lastConnectionRefresh {
                    Text("列表最近核对于 \(date.formatted(date: .abbreviated, time: .shortened))。")
                        .font(.caption).foregroundStyle(RecordDesign.secondary)
                } else {
                    Text("点击刷新，从服务端读取当前授权列表。")
                        .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                }
                Button("刷新授权列表") { store.refreshConnections() }
                    .buttonStyle(RecordSecondaryButtonStyle())
                    .disabled(!store.hasSavedSignIn || store.isWorking)
                if store.connections.isEmpty, store.lastConnectionRefresh != nil {
                    Text("当前账户没有 Agent 授权。")
                        .font(.subheadline).foregroundStyle(RecordDesign.secondary)
                }
                ForEach(store.connections) { connection in
                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(connection.clientName).font(.headline)
                        Text(connection.isActive ? "已授权 · \(connection.recordingIDs.count) 段" : "已撤销")
                            .font(.subheadline)
                        Text(connection.scopes.map(\.title).joined(separator: "、"))
                            .font(.caption).foregroundStyle(RecordDesign.secondary)
                        Text("批准于 \(connection.createdAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(RecordDesign.secondary)
                        if connection.isActive {
                            Button("撤销这项授权", role: .destructive) { revokeTarget = connection }
                                .buttonStyle(RecordSecondaryButtonStyle()).disabled(store.isWorking)
                        }
                    }
                }
            }.fixedSize(horizontal: false, vertical: true).recordCard().recordRow()
        }
    }

    private func identityLine(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(RecordDesign.secondary)
            Text(verbatim: value).font(.subheadline.monospaced()).textSelection(.enabled)
        }
    }
}
