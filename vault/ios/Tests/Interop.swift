import Foundation

/// swiftc ContextVaultCapture/Transfer.swift Tests/Interop.swift -o /tmp/context-vault-seal
/// /tmp/context-vault-seal 'CV1.…' /path/to/new.cvdrop
@main enum Interop {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count == 3 else {
            FileHandle.standardError.write(Data("Usage: seal CV1.PUBLIC_KEY NEW_OUTPUT_PATH\n".utf8))
            throw IntakeError.invalidPairing
        }
        let recipient = try VaultRecipient(code: args[1])
        let pdf = Data("%PDF-1.4\n% Synthetic Context Vault cross-platform fixture.\n%%EOF\n".utf8)
        let drop = try VaultDocument(bytes: pdf, mime: "application/pdf")
            .seal(label: "合成跨端测试", to: recipient)
        try drop.write(to: URL(fileURLWithPath: args[2]), options: [.withoutOverwriting])
        print(recipient.fingerprint)
    }
}
