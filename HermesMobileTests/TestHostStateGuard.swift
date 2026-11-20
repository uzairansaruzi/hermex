import Foundation
import Security
import XCTest

final class TestHostStateGuard: NSObject, XCTestObservation {
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

    func testCaseWillStart(_ testCase: XCTestCase) {
        HermesHostFixture.reset()
        MainActor.assumeIsolated { XCTestCase.warmUpSoftwareKeyboard() }
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

    private static func identity(of item: [String: Any]) -> [String: Any] {
        var identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword]
        for key in [kSecAttrService, kSecAttrAccount, kSecAttrAccessGroup, kSecAttrSynchronizable] as [CFString] {
            identity[key as String] = item[key as String]
        }
        return identity
    }

    private static let restoredAttributes = [
        kSecValueData, kSecAttrAccessible, kSecAttrLabel, kSecAttrComment, kSecAttrDescription, kSecAttrGeneric,
    ].map { $0 as String }
}
