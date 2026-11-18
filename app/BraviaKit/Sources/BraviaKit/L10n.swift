import Foundation

/// User-facing strings that tests compare against. Tests call the same accessors, so they pass
/// whatever the system language is. Other strings are localized in place with `String(localized:)`.
enum L10n {
    static var enterTVAddress: String {
        String(
            localized: "Enter the TV's IP address (for example, 192.168.1.50) or a name like bravia.local.",
            bundle: .module,
            comment: "Error: plain HTTP to this host is blocked by App Transport Security."
        )
    }

    static var blasterConnected: String {
        String(localized: "IR bridge connected", bundle: .module, comment: "Banner after the IR bridge is paired.")
    }
}
