import AppKit

/// Register bundle identifier for window tab support
let bundleInfo: NSDictionary = [
    "CFBundleIdentifier": "com.example.ListExampleMac",
    "CFBundleName": "ListExampleMac",
]
UserDefaults.standard.register(defaults: bundleInfo as! [String: Any])

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
