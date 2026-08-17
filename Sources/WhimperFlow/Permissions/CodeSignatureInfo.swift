import Foundation
import Security

/// Facts about how this copy of WhimperFlow is signed.
///
/// TCC (the privacy database behind Microphone / Speech Recognition /
/// Accessibility) records a *code requirement* alongside every grant. For an
/// app signed with a real certificate that requirement names the certificate,
/// so rebuilds keep their permissions. For an ad-hoc signature there is no
/// certificate to name, so the grant is bound to the bundle's cdhash — which
/// changes on every `make app`. The result is the failure mode this app hit:
/// System Settings still lists WhimperFlow as allowed, but the running app
/// reads "not granted" and macOS never re-prompts, because from TCC's point of
/// view a decision already exists for a *different* binary.
///
/// `PermissionsManager` uses this to tell "the user hasn't granted it yet"
/// apart from "a rebuild invalidated a grant the user already made", which
/// need completely different advice.
enum CodeSignatureInfo {
    /// The running app's cdhash, hex-encoded — the identity TCC keys ad-hoc
    /// signed apps on. Nil when running unsigned or outside a bundle.
    static let cdHash: String? = signingInfo().cdHash

    /// True when this build is ad-hoc signed (`codesign --sign -`) or
    /// unsigned, i.e. its permission grants do not survive a rebuild.
    static let isAdHoc: Bool = signingInfo().isAdHoc

    /// `kSecCodeSignatureAdhoc`, which isn't exposed to Swift.
    private static let adhocFlag: UInt32 = 0x0000_0002

    private static func signingInfo() -> (cdHash: String?, isAdHoc: Bool) {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else {
            return (nil, true)
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return (nil, true)
        }
        var infoCF: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation)
        guard SecCodeCopySigningInformation(staticCode, flags, &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else {
            return (nil, true)
        }

        let hash = (info[kSecCodeInfoUnique as String] as? Data)
            .map { $0.map { String(format: "%02x", $0) }.joined() }

        // No certificate chain at all means ad-hoc (or unsigned).
        let certificates = info[kSecCodeInfoCertificates as String] as? [Any]
        let signatureFlags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let adhoc = (signatureFlags & adhocFlag) != 0 || (certificates?.isEmpty ?? true)

        return (hash, adhoc)
    }
}
