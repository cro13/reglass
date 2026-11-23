import Foundation

/// Locates the optional sign-in data in the package's processed Resources directory.
enum AccountResources {
    static var bloksFunctionMap: URL? {
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "bloks-functions", withExtension: "txt")
        #else
        // The standalone swiftc check has no generated package bundle.
        return Bundle.main.url(forResource: "bloks-functions", withExtension: "txt")
        #endif
    }
}
