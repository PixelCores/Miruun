import AppKit
import Darwin

// Restrict newly created local files, including Foundation atomic-write temps.
umask(0o077)
let application = NSApplication.shared
let delegate = MenuAppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()
