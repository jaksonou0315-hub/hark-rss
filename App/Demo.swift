import Foundation

/// Launch-argument hooks used only for simulator screenshots. Release builds ignore them.
enum Demo {
    static func flag(_ key: String) -> Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: key)
        #else
        return false
        #endif
    }
    static func int(_ key: String) -> Int {
        #if DEBUG
        return UserDefaults.standard.integer(forKey: key)
        #else
        return 0
        #endif
    }
}
