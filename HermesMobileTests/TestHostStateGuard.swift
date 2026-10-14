import Foundation
import Security
import XCTest

/// Keeps a test run from signing the simulator's Hermex out. The tests run inside the app as
/// their host, so a test that reaches the real Keychain, cookie jar or standard defaults changes
/// the app's saved servers, credentials and sessions. As the bundle's principal class
/// (`INFOPLIST_KEY_NSPrincipalClass`) it snapshots all three when the bundle starts and puts them
/// back when it finishes, for `scripts/test-sim`, Xcode and CI alike. A run killed before it
/// finishes leaves whatever the tests wrote.
final class TestHostStateGuard: NSObject, XCTestObservation {
    /// Nil when the Keychain could not be read, so the restore leaves it alone.
    private var keychainItems: [[String: Any]]?
    private var cookies: [HTTPCookie] = []
    private var defaults: [String: Any]?

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        keychainItems = Self.genericPasswords(returningData: true)
        cookies = HTTPCookieStorage.shared.cookies ?? []
        defaults = Bundle.main.bundleIdentifier.flatMap(UserDefaults.standard.persistentDomain(forName:))
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        if let keychainItems, let current = Self.genericPasswords(returningData: false) {
            for item in current {
                SecItemDelete(Self.identity(of: item) as CFDictionary)
            }
            for item in keychainItems {
                var restored = Self.identity(of: item)
                for key in Self.restoredAttributes { restored[key] = item[key] }
                SecItemAdd(restored as CFDictionary, nil)
            }
        }

        HTTPCookieStorage.shared.cookies?.forEach(HTTPCookieStorage.shared.deleteCookie)
        cookies.forEach(HTTPCookieStorage.shared.setCookie)

        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        if let defaults {
            UserDefaults.standard.setPersistentDomain(defaults, forName: bundleID)
        } else {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
    }

    /// Every generic password the host app can reach, in all of its access groups; nil when the
    /// read fails, which must never pass for an empty Keychain.
    private static func genericPasswords(returningData: Bool) -> [[String: Any]]? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: returningData,
        ]
        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecSuccess: return result as? [[String: Any]]
        case errSecItemNotFound: return []
        default: return nil
        }
    }

    /// The attributes that name one item, for deleting it or adding it back.
    private static func identity(of item: [String: Any]) -> [String: Any] {
        var identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword]
        for key in [kSecAttrService, kSecAttrAccount, kSecAttrAccessGroup, kSecAttrSynchronizable] as [CFString] {
            identity[key as String] = item[key as String]
        }
        return identity
    }

    /// What an added item carries beyond its identity. Read-only attributes such as creation
    /// dates would make `SecItemAdd` fail.
    private static let restoredAttributes = [
        kSecValueData, kSecAttrAccessible, kSecAttrLabel, kSecAttrComment, kSecAttrDescription, kSecAttrGeneric,
    ].map { $0 as String }
}
