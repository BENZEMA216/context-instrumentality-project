import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let vaultDrop = UTType(exportedAs: "org.contextinstrumentality.vault.drop", conformingTo: .data)
}

struct EncryptedExport: FileDocument {
    static var readableContentTypes: [UTType] { [.vaultDrop] }
    let bytes: Data
    init(bytes: Data) { self.bytes = bytes }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.bytes = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: bytes)
    }
}

extension VaultDocument {
    static func read(_ url: URL) throws -> Self {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let value = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey, .fileSizeKey])
        guard value.isRegularFile == true, let type = value.contentType else { throw IntakeError.invalidType }
        if let size = value.fileSize, size > maxBytes { throw IntakeError.oversized }
        let mime: String
        if type.conforms(to: .pdf) { mime = "application/pdf" }
        else if type.conforms(to: .jpeg) { mime = "image/jpeg" }
        else if type.conforms(to: .png) { mime = "image/png" }
        else { throw IntakeError.invalidType }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let bytes = try file.read(upToCount: maxBytes + 1) ?? Data()
        return try VaultDocument(bytes: bytes, mime: mime)
    }
}
