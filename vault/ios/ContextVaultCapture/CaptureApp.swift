import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import VisionKit

@main struct ContextVaultCapture: App {
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            ZStack {
                CaptureView()
                if phase == .background { CanvasPaper().ignoresSafeArea() }
            }
        }
    }
}

private struct CanvasPaper: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View { scheme == .dark ? Color(red: 0.08, green: 0.08, blue: 0.07)
                                         : Color(red: 0.97, green: 0.96, blue: 0.94) }
}

private struct CaptureView: View {
    @AppStorage("vault-recipient-public-key-v1") private var storedCode = ""
    @State private var code = ""
    @State private var editingPair = false
    @State private var category = "身份证"
    @State private var label = "身份证"
    @State private var document: VaultDocument?
    @State private var scanning = false
    @State private var choosingFile = false
    @State private var exporting = false
    @State private var exported: EncryptedExport?
    @State private var filename = ""
    @State private var notice = ""
    @State private var busy = false
    @State private var lastError: String?
    private let categories = ["身份证", "营业执照", "学位证", "工资证明", "其他"]
    private var recipient: VaultRecipient? { try? VaultRecipient(code: storedCode) }
    @Environment(\.colorScheme) private var scheme
    private var accent: Color { scheme == .dark ? Color(red: 1, green: 0.55, blue: 0.36)
                                                : Color(red: 0.61, green: 0.22, blue: 0.09) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 5) {
                        Label("Context · iPhone", systemImage: "lock.doc").font(.subheadline)
                            .foregroundStyle(.secondary)
                        (Text("Vault") + Text(".").foregroundColor(accent))
                            .font(.system(size: 64, weight: .medium, design: .serif)).tracking(-3)
                        Text("证件收件箱").font(.title3.weight(.medium))
                    }
                    Divider()
                    if let recipient, !editingPair {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Label("接收保险库", systemImage: "laptopcomputer")
                                Text(recipient.fingerprint).font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(.secondary).accessibilityIdentifier("fingerprint")
                            }
                            Spacer()
                            Button("更换") { code = ""; editingPair = true; notice = "" }
                        }
                        intake
                    } else {
                        pairing
                    }
                    if !notice.isEmpty {
                        Label(notice, systemImage: "info.circle").font(.footnote)
                            .foregroundStyle(.secondary).accessibilityIdentifier("notice")
                    }
                }
                .padding(24).frame(maxWidth: 600)
            }
            .background(CanvasPaper().ignoresSafeArea())
            .tint(accent)
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(isPresented: $scanning) {
            DocumentScanner { result in
                scanning = false
                if let result { accept(result) }
            }.ignoresSafeArea()
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.pdf, .jpeg, .png]) { result in
            do {
                let url = try result.get()
                busy = true
                Task {
                    let loaded = await Task.detached(priority: .userInitiated) { Result { try VaultDocument.read(url) } }.value
                    busy = false
                    accept(loaded)
                }
            } catch { if !isUserCancelled(error) { lastError = error.localizedDescription } }
        }
        .fileExporter(isPresented: $exporting, document: exported, contentType: .vaultDrop,
                      defaultFilename: filename) { result in
            switch result {
            case .success:
                document = nil
                notice = "加密文件已保存。可在 Mac 的“手机收件”中确认导入。"
            case .failure(let error):
                if !isUserCancelled(error) { lastError = "保存失败。资料仍在本页，可重新导出。" }
            }
            exported = nil
        }
        .alert("无法完成操作", isPresented: Binding(get: { lastError != nil }, set: { if !$0 { lastError = nil } })) {
            Button("好") { lastError = nil }
        } message: { Text(lastError ?? "") }
    }

    private var pairing: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("配对接收保险库").font(.headline)
            Text("从 Mac 的 Vault 复制公钥配对码，核对公钥指纹后可重复使用。")
                .font(.subheadline).foregroundStyle(.secondary)
            TextField("CV1.…", text: $code).textInputAutocapitalization(.never)
                .autocorrectionDisabled().font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder).accessibilityLabel("公钥配对码")
                .accessibilityIdentifier("pairCode")
            if let candidate = try? VaultRecipient(code: code) {
                Text(candidate.fingerprint).font(.system(.footnote, design: .monospaced))
            }
            HStack {
                Button("保存配对") {
                    do {
                        let next = try VaultRecipient(code: code)
                        storedCode = next.code
                        code = ""
                        editingPair = false
                        notice = "已保存接收方公钥。"
                    } catch { lastError = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(code.isEmpty)
                if recipient != nil { Button("取消") { code = ""; editingPair = false } }
            }
        }
    }

    private var intake: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("资料类型") {
                Picker("资料类型", selection: $category) {
                    ForEach(categories, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().pickerStyle(.menu).accessibilityIdentifier("category")
            }
            .onChange(of: category) { old, new in
                if label.isEmpty || label == old { label = new }
            }
            TextField("资料名称", text: $label).textFieldStyle(.roundedBorder)
                .accessibilityLabel("资料名称").accessibilityIdentifier("documentLabel")
            Divider()
            Button(action: beginScanning) { Label("扫描证件", systemImage: "document.viewfinder") }
            Button(action: { choosingFile = true }) { Label("从文件选取", systemImage: "folder") }
            Text("最多扫描 16 页。每份 PDF、JPEG 或 PNG 需在 8 MiB 以内。")
                .font(.footnote).foregroundStyle(.secondary)
            if let document {
                HStack {
                    Image(systemName: "doc.fill")
                    Text(document.mime + " · " + ByteCountFormatter.string(fromByteCount: Int64(document.bytes.count),
                                                                      countStyle: .file)).font(.footnote)
                    Spacer()
                    Button("移除") { self.document = nil; notice = "" }
                }
            }
            Button("加密并存入文件") { exportDocument() }
                .buttonStyle(.borderedProminent)
                .disabled(document == nil || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || busy)
            Text("Mac 已开启 iCloud 收件时，存到 iCloud Drive / Context Vault / Inbox。也可保存在“我的 iPhone”后自行传送。")
                .font(.footnote).foregroundStyle(.secondary)
        }.disabled(busy)
    }

    private func beginScanning() {
        guard VNDocumentCameraViewController.isSupported else {
            lastError = "此设备无法使用文档扫描。可以从“文件”选取资料。"
            return
        }
        let permissionHelp = "请在系统设置中允许 Context Vault 使用相机，或从“文件”选取资料。"
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: scanning = true
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .video) { scanning = true }
                else { lastError = permissionHelp }
            }
        default: lastError = permissionHelp
        }
    }

    private func isUserCancelled(_ error: Error) -> Bool {
        let err = error as NSError
        return err.domain == NSCocoaErrorDomain && err.code == NSUserCancelledError
    }
    private func accept(_ result: Result<VaultDocument, Error>) {
        switch result {
        case .success(let value): document = value; notice = ""
        case .failure(let error): lastError = error.localizedDescription
        }
    }
    private func exportDocument() {
        guard let document, let recipient else { return }
        do {
            exported = EncryptedExport(bytes: try document.seal(label: label, to: recipient))
            filename = "context-" + UUID().uuidString.lowercased()
            exporting = true
        } catch { lastError = error.localizedDescription }
    }
}
