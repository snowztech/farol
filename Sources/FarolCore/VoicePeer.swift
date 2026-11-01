import Foundation
import Security

/// Tells Farol Voice from any other program on the socket, by the signature of what's connected rather than anything it says about itself.
/// Otherwise an agent could claim to be Farol Voice and get around the setting that stops agents messaging each other.
public enum VoicePeer {
    /// Both its release and its dev build, from this team only.
    static let requirement = #"anchor apple generic and certificate leaf[subject.OU] = "X935Q2B2RF" and (identifier "dev.farol.Voice" or identifier "dev.farol.Voice.debug")"#

    static func isFarolVoice(descriptor: Int32) -> Bool {
        var token = audit_token_t()
        var size = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &size) == 0 else { return false }
        let audit = withUnsafeBytes(of: &token) { Data($0) }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: audit] as CFDictionary
        var compiled: SecRequirement?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled else { return false }
        return SecCodeCheckValidity(code, [], compiled) == errSecSuccess
    }
}
