// Renders the app icon: swift scripts/make_icon.swift <out.png>
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGradient(colors: [NSColor(red: 0.20, green: 0.45, blue: 0.98, alpha: 1), NSColor(red: 0.42, green: 0.27, blue: 0.93, alpha: 1)])!
    .draw(in: path, angle: -60)
let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "tray.full.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 - 10, width: s.width, height: s.height))
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
