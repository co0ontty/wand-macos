import AppKit
import SwiftUI
import XCTest
@testable import Wand

@MainActor
final class ChatImagePreviewTests: XCTestCase {
    override func tearDown() {
        ChatImagePreviewPresenter.shared.close()
        super.tearDown()
    }

    func testMarkdownImagesKeepCodeAndRejectUnsafeSources() {
        let pieces = splitMarkdownImages("说明 ![截图](https://example.test/a.png \"标题\") 继续 `![隐藏](https://example.test/b.png)`")
        XCTAssertEqual(pieces, [
            .text("说明 "),
            .image(alt: "截图", source: "https://example.test/a.png"),
            .text(" 继续 `![隐藏](https://example.test/b.png)`"),
        ])
        XCTAssertEqual(splitMarkdownImages("\\![不是图片](https://example.test/a.png)"), [
            .text("![不是图片](https://example.test/a.png)"),
        ])
        XCTAssertNil(resolvedChatImageSource("javascript:alert(1)"))
        XCTAssertNil(resolvedChatImageSource("//evil.test/a.png"))
        XCTAssertNil(resolvedChatImageSource("file:///tmp/a.png"))
        XCTAssertEqual(resolvedChatImageSource("https://example.test/a.png"), "https://example.test/a.png")
        XCTAssertEqual(resolvedChatImageSource("/api/sessions/s/tool-images/a.png"), "/api/sessions/s/tool-images/a.png")
        XCTAssertEqual(
            resolvedChatImageSource("/Users/me/my file.png"),
            "/api/file-raw?path=" + chatImageQueryEncoded("/Users/me/my file.png")
        )
        XCTAssertEqual(chatImageLabel(source: "/api/sessions/s/tool-images/a%20b.png", fallback: "图片"), "a b.png")
        XCTAssertEqual(chatImageLabel(source: "data:image/png;base64,aaaa", fallback: "工具返回图片"), "工具返回图片")
    }

    func testPreviewFileIsPNGAndClickOpensThenClosesWithoutLeavingTheMessage() async throws {
        let sample = try sampleImage()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wand-image-preview-test-\(UUID().uuidString).png")
        try writeChatPreviewPNG(sample.image, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let written = try Data(contentsOf: url)
        XCTAssertEqual(written.prefix(8), Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))

        let host = NSHostingView(rootView: PreviewProbe(image: sample.image))
        host.frame = NSRect(x: 0, y: 0, width: 720, height: 520)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        defer {
            ChatImagePreviewPresenter.shared.close()
            window.contentView = nil
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        let opener = try await waitForProbe("chat-image-open-验收图", in: host)
        XCTAssertGreaterThan(opener.bounds.width, 1)
        click(opener)
        let sheet = try XCTUnwrap(presentedPreview(titled: "验收图", from: window))
        XCTAssertEqual(sheet.title, "验收图")
        let closer = try await waitForProbe("chat-image-close", in: try XCTUnwrap(sheet.contentView))
        click(closer)
        try await waitUntil { window.attachedSheet == nil }
        XCTAssertNil(window.attachedSheet)
        XCTAssertNotNil(probe("chat-image-open-验收图", in: host))
        XCTAssertEqual(window.contentView, host)
    }

    func testStructuredToolAndMarkdownImagesOpenFromTheMessage() async throws {
        let sample = try sampleImage()
        let baseURL = try XCTUnwrap(URL(string: "https://fixture.example.test"))
        let toolTurn = ConversationTurn(role: "assistant", content: [
            .toolUse(id: "tool-1", name: "Read", description: "读取截图", input: [:], subagent: nil),
            .toolResult(toolUseId: "tool-1", text: "工具说明仍可选择", isError: false, truncated: false, images: [sample.uri], subagent: nil),
        ])
        let markdownTurn = ConversationTurn(role: "assistant", content: [
            .text(text: "正文保留\n\n![验收图](\(sample.uri))\n\n`![不要打开](\(sample.uri))`", subagent: nil),
        ])
        let host = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
            TurnView(turn: toolTurn, baseURL: baseURL, showHeader: false)
            TurnView(turn: markdownTurn, baseURL: baseURL, showHeader: false)
        }.frame(width: 640))
        host.frame = NSRect(x: 0, y: 0, width: 680, height: 720)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        defer {
            ChatImagePreviewPresenter.shared.close()
            window.contentView = nil
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        let markdown = try await waitForProbe("chat-image-open-验收图", in: host)
        let tool = try await waitForProbe("chat-image-open-工具返回图片", in: host)
        XCTAssertNil(probe("chat-image-open-不要打开", in: host))
        XCTAssertFalse(descendants(host).isEmpty)
        click(tool)
        var sheet = try XCTUnwrap(presentedPreview(titled: "工具返回图片", from: window), "工具图片点击后应立刻挂出预览")
        XCTAssertEqual(sheet.title, "工具返回图片")
        ChatImagePreviewPresenter.shared.close()
        try await waitUntil { presentedPreview(titled: "工具返回图片", from: window) == nil }
        click(tool)
        sheet = try XCTUnwrap(presentedPreview(titled: "工具返回图片", from: window), "同一张图片关闭后应能再次打开")
        XCTAssertEqual(sheet.title, "工具返回图片")
        ChatImagePreviewPresenter.shared.close()
        try await waitUntil { presentedPreview(titled: "工具返回图片", from: window) == nil }
        click(markdown)
        sheet = try XCTUnwrap(presentedPreview(titled: "验收图", from: window), "另一张图片应打开自己的预览")
        XCTAssertEqual(sheet.title, "验收图")
        ChatImagePreviewPresenter.shared.close()
        try await waitUntil { presentedPreview(titled: "验收图", from: window) == nil }
        XCTAssertNotNil(probe("chat-image-open-验收图", in: host))
        XCTAssertNotNil(probe("chat-image-open-工具返回图片", in: host))
        XCTAssertEqual(window.contentView, host)
    }

    private func sampleImage() throws -> (image: NSImage, uri: String) {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 6,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemRed.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 6).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: 8, height: 6))
        image.addRepresentation(rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        return (image, "data:image/png;base64,\(png.base64EncodedString())")
    }

    private func descendants(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(descendants)
    }

    private func probe(_ id: String, in root: NSView) -> NSView? {
        descendants(root).first { $0.identifier?.rawValue == id && $0.bounds.width > 0 && $0.bounds.height > 0 }
    }

    private func waitForProbe(_ id: String, in root: NSView) async throws -> NSView {
        for _ in 0..<40 {
            root.layoutSubtreeIfNeeded()
            if let found = probe(id, in: root) { return found }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let ids = descendants(root).compactMap { $0.identifier?.rawValue }
        XCTFail("未找到可点击区域 \(id)；ids=\(ids)")
        return try XCTUnwrap(probe(id, in: root))
    }

    private func click(_ view: NSView) {
        guard let window = view.window else {
            XCTFail("点击目标不在窗口里")
            return
        }
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        let location = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )
            if let event { window.sendEvent(event) }
        }
    }

    private func presentedPreview(titled title: String, from window: NSWindow) -> NSWindow? {
        if let sheet = window.attachedSheet, sheet.title == title { return sheet }
        return NSApp.windows.first { $0.title == title && $0.isVisible && $0 !== window }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<30 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(condition())
    }

    private struct PreviewProbe: View {
        let image: NSImage
        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("可选正文保持在原位，点图片不应把这段文字换掉。")
                        .textSelection(.enabled)
                    ChatImageOpenButton(image: image, label: "验收图") {
                        Image(nsImage: image)
                            .resizable()
                            .frame(width: 80, height: 60)
                    }
                }
                .padding(16)
            }
        }
    }
}
