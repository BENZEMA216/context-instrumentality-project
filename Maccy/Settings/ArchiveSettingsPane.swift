import AppKit
import SwiftUI

struct ArchiveSettingsPane: View {
  @State private var archive = ClipboardArchive.shared
  @ObservedObject private var googleDrive = AppDelegate.googleDrive
  @State private var showingDriveSetup = false
  @State private var showingAllConfirmation = false
  @State private var showingDriveDisconnect = false
  @State private var clientID = ""
  @State private var clientSecret = ""
  @State private var working = false
  @State private var errorMessage: String?
  @State private var copyFeedback: String?

  var body: some View {
    @Bindable var archive = archive

    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 4) {
        Text("剪贴板目录")
          .font(.system(size: 15, weight: .semibold))
          .accessibilityAddTraits(.isHeader)
        Text("在这里选择 Codex 和 Claude Code 可以读取的剪贴板内容。")
          .foregroundStyle(.secondary)
      }

      ClipSettingsGroup(Text("共享范围")) {
        VStack(alignment: .leading, spacing: 10) {
          Picker("共享方式", selection: Binding(get: { archive.policy }, set: choosePolicy)) {
            Text("关闭").tag(ClipboardArchive.Policy.off)
            Text("手动选择").tag(ClipboardArchive.Policy.manual)
            Text("收藏与手动选择").tag(ClipboardArchive.Policy.pinned)
            Text("所有历史").tag(ClipboardArchive.Policy.all)
          }
          Text("右键单条历史可分享或撤销。密码管理器标记为机密的条目和已忽略的内容会被跳过。")
            .font(.callout)
            .foregroundStyle(.secondary)

          HStack {
            Picker("同步间隔", selection: $archive.intervalMinutes) {
              Text("1 分钟").tag(1)
              Text("5 分钟").tag(5)
              Text("15 分钟").tag(15)
              Text("60 分钟").tag(60)
            }
            .fixedSize()
            Spacer()
            if archive.isPublishing {
              ProgressView().controlSize(.small).accessibilityLabel("正在同步")
            }
            Button("立即同步") { archive.syncNow() }
              .disabled(archive.isPublishing || !archive.canSync)
              .help("选择共享方式后可同步。曾共享过的目录可以同步为空。")
          }
          if let error = archive.localError {
            Text(error).foregroundStyle(.red).font(.callout)
          } else if let date = archive.lastSync {
            Text("已写入 \(archive.lastItemCount) 条 · \(date.formatted(date: .omitted, time: .shortened))")
              .font(.callout)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
      }

      ClipSettingsGroup(Text("同步位置")) {
        VStack(alignment: .leading, spacing: 10) {
          destinationRow("本机目录", symbol: "folder", detail: archive.localURL.deletingLastPathComponent().path) {
            Button("在 Finder 中显示") {
              NSWorkspace.shared.activateFileViewerSelecting([archive.localURL])
            }
            .disabled(archive.lastSync == nil)
          }
          Divider()
          destinationRow("iCloud Drive", symbol: "icloud", detail: archive.folder(for: .iCloudDrive)?.path) {
            if archive.folder(for: .iCloudDrive) != nil {
              Button("断开") { changeFolder { try archive.disconnect(.iCloudDrive) } }
            }
            Button("选择文件夹…") { selectICloudFolder() }
          }
          if let status = archive.destinationStatus(for: .iCloudDrive) {
            Text(status)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Divider()
          destinationRow("Google Drive", symbol: "externaldrive.connected.to.line.below", detail: driveStatus) {
            if googleDrive.isConnected {
              if let id = googleDrive.latestFileID,
                 let url = URL(string: "https://drive.google.com/open?id=\(id)") {
                Link("打开副本", destination: url)
              }
              Button("断开") { showingDriveDisconnect = true }
                .disabled(archive.isPublishing || working)
            } else {
              Button("连接…") { showingDriveSetup = true }
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
      }

      ClipSettingsGroup(Text("Agent 接入")) {
        VStack(alignment: .leading, spacing: 8) {
          Text("复制命令到终端注册只读 MCP。定时简报可在 Agent 的定时任务中使用同一个目录。")
            .foregroundStyle(.secondary)
            .font(.callout)
          HStack {
            Button("复制 Codex 命令") { copySetup(for: .codex) }
            Button("复制 Claude Code 命令") { copySetup(for: .claude) }
            Button("使用说明") { openGuide() }
          }
          Menu("复制简报命令") {
            Button("用 Codex 生成") { copyDigest(for: .codex) }
            Button("用 Claude Code 生成") { copyDigest(for: .claude) }
          }
          .fixedSize()
          if let copyFeedback {
            Text(copyFeedback).font(.callout).foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 10)
      }
    }
    .sheet(isPresented: $showingDriveSetup) { driveSetup }
    .alert("允许 Agent 读取所有历史？", isPresented: $showingAllConfirmation) {
      Button("允许所有历史") { archive.policy = .all }
      Button("取消", role: .cancel) { }
    } message: {
      Text("本机现有和后续采集的历史会自动进入共享目录。已连接的云盘也会收到这份目录。你可右键撤销单条共享。")
    }
    .confirmationDialog("断开 Google Drive？", isPresented: $showingDriveDisconnect) {
      Button("断开", role: .destructive) {
        changeFolder {
          try googleDrive.disconnect()
          AppDelegate.configureGoogleDrive()
        }
      }
    } message: {
      Text("云端最后一份目录会保留。你可以在 Google Drive 中删除它，或先在本页关闭共享并同步空目录。")
    }
    .alert("操作失败", isPresented: Binding(
      get: { errorMessage != nil && !showingDriveSetup },
      set: { if !$0 { errorMessage = nil } }
    )) {
      Button("好") { errorMessage = nil }
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private var driveStatus: String {
    if let error = archive.remoteError { return error }
    if let date = archive.remoteLastSync { return "上次上传 \(date.formatted(date: .abbreviated, time: .shortened))" }
    return googleDrive.isConnected ? "已连接，等待同步" : "使用 Google 账号授权"
  }

  private var driveSetup: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("连接 Google Drive").font(.title2.weight(.semibold))
      Text("在 Google Cloud 启用 Drive API 并创建 Desktop app 类型的 OAuth 客户端。ClipContext 将在浏览器中请求授权。")
        .foregroundStyle(.secondary)
      Link("打开 Google Cloud OAuth 客户端", destination: URL(string: "https://console.cloud.google.com/auth/clients")!)
      TextField("OAuth 客户端 ID", text: $clientID)
      SecureField("OAuth 客户端密钥", text: $clientSecret)
      if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
      HStack {
        if working { ProgressView().controlSize(.small) }
        Spacer()
        Button("取消") { showingDriveSetup = false; errorMessage = nil; clientSecret = "" }
          .disabled(working)
          .keyboardShortcut(.cancelAction)
        Button("在浏览器中授权") { connectDrive() }
          .disabled(working || clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(24)
    .frame(width: 460)
  }

  private enum Client { case codex, claude }

  private func destinationRow<Actions: View>(
    _ title: String, symbol: String, detail: String?, @ViewBuilder actions: () -> Actions
  ) -> some View {
    HStack(spacing: 10) {
      Image(systemName: symbol)
        .foregroundStyle(.secondary)
        .frame(width: 20)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).fontWeight(.medium)
        if let detail {
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .help(detail)
        }
      }
      Spacer(minLength: 10)
      actions()
        .fixedSize()
    }
  }

  private func choosePolicy(_ policy: ClipboardArchive.Policy) {
    if policy == .all && archive.policy != .all {
      showingAllConfirmation = true
    } else {
      archive.policy = policy
    }
  }

  private func selectICloudFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = "使用此文件夹"
    panel.message = "在 iCloud Drive 中选择保存目录的位置。ClipContext 会在里面创建自己的文件夹。"
    panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
      .appending(path: "Library/Mobile Documents/com~apple~CloudDocs", directoryHint: .isDirectory)
    panel.begin { response in
      guard response == .OK, let url = panel.url else { return }
      changeFolder { try archive.setFolder(url, for: .iCloudDrive) }
    }
  }

  private func changeFolder(_ action: () throws -> Void) {
    do { try action() } catch { errorMessage = error.localizedDescription }
  }

  private func connectDrive() {
    errorMessage = nil
    working = true
    Task {
      defer { working = false }
      do {
        try await googleDrive.authorize(
          clientID: clientID.trimmingCharacters(in: .whitespacesAndNewlines),
          clientSecret: clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        clientSecret = ""
        showingDriveSetup = false
        AppDelegate.configureGoogleDrive()
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func copySetup(for client: Client) {
    guard let helper = Bundle.main.url(forResource: "clipcontext-mcp", withExtension: "py") else { return }
    let invocation = "/usr/bin/python3 \(shellQuote(helper.path)) --archive \(shellQuote(archive.localURL.path))"
    let command: String
    switch client {
    case .codex: command = "\(installedExecutable(for: .codex).map(shellQuote) ?? "codex") mcp add clipcontext -- \(invocation)"
    case .claude: command = "\(installedExecutable(for: .claude).map(shellQuote) ?? "claude") mcp add --scope user clipcontext -- \(invocation)"
    }
    copyCommand(command)
  }

  private func copyDigest(for client: Client) {
    guard let helper = Bundle.main.url(forResource: "clipcontext-digest", withExtension: "py") else { return }
    let name = client == .codex ? "codex" : "claude"
    let reports = archive.localURL.deletingLastPathComponent().deletingLastPathComponent()
      .appending(path: "Reports", directoryHint: .isDirectory)
    var command = "/usr/bin/python3 \(shellQuote(helper.path)) --archive \(shellQuote(archive.localURL.path))"
    command += " --runner \(name) --output-dir \(shellQuote(reports.path))"
    if let executable = installedExecutable(for: client) {
      command += " --agent-bin \(shellQuote(executable))"
    }
    copyCommand(command)
  }

  private func installedExecutable(for client: Client) -> String? {
    let name = client == .codex ? "codex" : "claude"
    let homeBin = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin/\(name)")
    var candidates = [homeBin.path, "/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)"]
    if client == .codex {
      candidates.insert("/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex", at: 0)
    }
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  private func copyCommand(_ command: String) {
    copyFeedback = Clipboard.shared.copyAgentCommand(command) ? "已复制命令" : "复制命令失败"
  }

  private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func openGuide() {
    if let guide = Bundle.main.url(forResource: "ClipContext-Guide", withExtension: "html") {
      NSWorkspace.shared.open(guide)
    }
  }
}
