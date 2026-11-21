import AppKit

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
let menu = NSMenu()
let appEntry = NSMenuItem()
let appMenu = NSMenu()
appMenu.addItem(withTitle: "退出 XR180", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appEntry.submenu = appMenu
menu.addItem(appEntry)
app.mainMenu = menu
app.run()
