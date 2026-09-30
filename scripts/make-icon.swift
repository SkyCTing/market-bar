#!/usr/bin/env swift
//
// 生成 AppIcon.icns。
//
//   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift scripts/make-icon.swift
//
// 图标含义（用户 2026-09 定的方向）：
//   · 金色对话气泡 = 助手（能聊天的桌面宠物）
//   · 气泡里的深色上升折线 = 行情（金价 / 自选股）
//   · 右上角红点 = 提醒
//
// 为什么是代码画的而不是一张位图：图标要 10 个尺寸（16 到 1024），
// 位图缩下去小尺寸会糊。这里每个尺寸都用同一套矢量坐标**重新绘制一遍**
// （见 render 里的 scale），16px 也是干净的。

import AppKit

// ── 画布约定：全部按 1024×1024 的坐标写，渲染时按目标尺寸缩放
let canvas: CGFloat = 1024
/// macOS 图标的圆角方形：四周留白后约占 824×824，圆角半径取 22.37%
let iconRect = NSRect(x: 100, y: 100, width: 824, height: 824)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: a)
}

func squircle(_ rect: NSRect) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)
}

/// 对话气泡：圆角矩形 + 左下角一个尾巴。
///
/// ⚠️ 必须画成**一条闭合轮廓**。用 `append` 把尾巴拼成第二段子路径的话，
/// 两段绕向相反，非零填充规则会把尾巴挖成一个洞（踩过，是个黑色三角）。
func speechBubble(_ rect: NSRect, radius r: CGFloat, tailX: CGFloat, tailSize: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
    let tx = minX + tailX
    let tip = NSPoint(x: tx - tailSize * 0.28, y: minY - tailSize)

    p.move(to: NSPoint(x: minX + r, y: minY))
    p.line(to: NSPoint(x: tx, y: minY))
    p.line(to: tip)
    p.line(to: NSPoint(x: tx + tailSize * 1.35, y: minY))
    p.line(to: NSPoint(x: maxX - r, y: minY))
    p.appendArc(withCenter: NSPoint(x: maxX - r, y: minY + r), radius: r, startAngle: 270, endAngle: 360)
    p.line(to: NSPoint(x: maxX, y: maxY - r))
    p.appendArc(withCenter: NSPoint(x: maxX - r, y: maxY - r), radius: r, startAngle: 0, endAngle: 90)
    p.line(to: NSPoint(x: minX + r, y: maxY))
    p.appendArc(withCenter: NSPoint(x: minX + r, y: maxY - r), radius: r, startAngle: 90, endAngle: 180)
    p.line(to: NSPoint(x: minX, y: minY + r))
    p.appendArc(withCenter: NSPoint(x: minX + r, y: minY + r), radius: r, startAngle: 180, endAngle: 270)
    p.close()
    return p
}

/// 整个图标。调用前画布已经缩放到目标尺寸，这里只写 1024 空间的坐标
func drawIcon() {
    let shape = squircle(iconRect)

    // 底：深蓝竖向渐变 + 顶部一层高光
    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(starting: rgb(0x2E4468), ending: rgb(0x111B2D))?.draw(in: iconRect, angle: -90)
    NSGradient(starting: rgb(0xFFFFFF, 0.12), ending: rgb(0xFFFFFF, 0))?
        .draw(in: NSRect(x: iconRect.minX, y: iconRect.midY,
                         width: iconRect.width, height: iconRect.height / 2), angle: -90)

    // 金色对话气泡
    let bubble = speechBubble(NSRect(x: 206, y: 296, width: 612, height: 460),
                              radius: 86, tailX: 96, tailSize: 82)
    NSGraphicsContext.saveGraphicsState()
    bubble.addClip()
    NSGradient(starting: rgb(0xFFDE8A), ending: rgb(0xE0A62C))?.draw(in: bubble.bounds, angle: -80)
    NSGraphicsContext.restoreGraphicsState()

    // 气泡里的上升折线
    let points = [NSPoint(x: 326, y: 408), NSPoint(x: 448, y: 508),
                  NSPoint(x: 566, y: 454), NSPoint(x: 708, y: 640)]
    let ink = rgb(0x2B2010, 0.92)
    ink.setStroke()
    ink.setFill()
    let line = NSBezierPath()
    line.lineWidth = 42
    line.lineCapStyle = .round
    line.lineJoinStyle = .round
    line.move(to: points[0])
    for p in points.dropFirst() { line.line(to: p) }
    line.stroke()
    for p in points {
        NSBezierPath(ovalIn: NSRect(x: p.x - 27, y: p.y - 27, width: 54, height: 54)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // 右上角红点（提醒），带一圈白边把它从气泡上托起来
    let center = NSPoint(x: bubble.bounds.maxX - 6, y: bubble.bounds.maxY - 4)
    let r: CGFloat = 66
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - r - 9, y: center.y - r - 9,
                                width: (r + 9) * 2, height: (r + 9) * 2)).fill()
    rgb(0xF2545E).setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r,
                                width: r * 2, height: r * 2)).fill()
}

/// 按目标像素尺寸重新绘制（不是缩放位图）
func render(pixels: Int) -> NSBitmapImageRep? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    ctx.shouldAntialias = true
    ctx.cgContext.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    drawIcon()
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// ── 产出 iconset → icns
let icnsName = "AppIcon.icns"
let projectDir = URL(fileURLWithPath: #filePath)          // …/scripts/make-icon.swift
    .deletingLastPathComponent()                          // …/scripts
    .deletingLastPathComponent()                          // 仓库根
let iconset = projectDir.appendingPathComponent("AppIcon.iconset")
let icns = projectDir.appendingPathComponent(icnsName)

// iconutil 要的就是这一组固定文件名
let entries: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for (name, px) in entries {
    guard let rep = render(pixels: px),
          let png = rep.representation(using: .png, properties: [:]) else {
        FileHandle.standardError.write("渲染失败: \(name) (\(px)px)\n".data(using: .utf8)!)
        exit(1)
    }
    try png.write(to: iconset.appendingPathComponent("\(name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil 失败（退出码 \(iconutil.terminationStatus)）\n".data(using: .utf8)!)
    exit(1)
}
try? FileManager.default.removeItem(at: iconset)

let size = ((try? FileManager.default.attributesOfItem(atPath: icns.path))?[.size] as? Int) ?? 0
print("✅ \(icns.path) (\(size) 字节)")
