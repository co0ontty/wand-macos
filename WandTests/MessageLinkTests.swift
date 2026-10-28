import AppKit
import Foundation
import XCTest
@testable import Wand

@MainActor
final class MessageLinkTests: XCTestCase {
    private let base = URL(string: "https://wand.test:8443/prefix")!
    private func preview(_ input: String, context: WandMessageFileContext = .init(), file: StaticString = #filePath, line: UInt = #line) -> URL? {
        guard case .preview(let url, _) = WandMessageLink.resolve(input, baseURL: base, context: context) else { XCTFail("Expected preview for \(input)", file: file, line: line); return nil }
        return url
    }
    private func download(_ input: String, context: WandMessageFileContext = .init(), file: StaticString = #filePath, line: UInt = #line) -> URL? {
        guard case .download(let url, _) = WandMessageLink.resolve(input, baseURL: base, context: context) else { XCTFail("Expected download for \(input)", file: file, line: line); return nil }
        return url
    }
    func testAbsoluteFileAndEncodedDelimitersPreservePathAndNavigation() throws {
        for input in ["/tmp/a%23b%3Fc.html?tab=a%2Bb#section", "file:///tmp/a%23b%3Fc.html?tab=a%2Bb#section"] {
            let url = try XCTUnwrap(preview(input))
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath, "/prefix/api/local-file/" + Data("/tmp/a#b?c.html".utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + "/")
            XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQuery, "tab=a%2Bb")
            XCTAssertEqual(url.fragment, "section")
        }
        let url = try XCTUnwrap(download("/tmp/report:2025"))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value, "/tmp/report:2025")
        XCTAssertNotNil(preview("~/site/"))
        let attachmentPath = "/tmp/中文 #问?号%25.txt"
        let attachmentLink = try XCTUnwrap(messageAttachmentURL(attachmentPath))
        let attachmentDownload = try XCTUnwrap(download(attachmentLink.absoluteString))
        XCTAssertEqual(URLComponents(url: attachmentDownload, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value, attachmentPath)
    }
    func testRelativeFilesUseTheirSourceAndNeverCurrentPage() throws {
        let target = try XCTUnwrap(preview("output/demo.html?theme=dark#details", context: .init(sessionID: "source")))
        XCTAssertEqual(target.path, "/prefix/api/session-file/source")
        let query = URLComponents(url: target, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "path" }?.value, "output/demo.html")
        XCTAssertEqual(query.first { $0.name == "search" }?.value, "?theme=dark")
        XCTAssertEqual(target.fragment, "details")
        guard case .unavailable = WandMessageLink.resolve("output/demo.html", baseURL: base) else { return XCTFail("Missing source must remain unavailable") }
        guard case .unavailable = WandMessageLink.resolve("../demo.html", baseURL: base, context: .init(cwd: "/work")) else { return XCTFail("Cwd traversal must fail") }
        let local = try XCTUnwrap(download("sub/../notes.txt", context: .init(cwd: "/work")))
        XCTAssertEqual(URLComponents(url: local, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value, "/work/notes.txt")
    }
    func testForwardedAPILinksAndLoopbackPreserveOrigin() throws {
        for input in ["localhost:5173/docs?x=1#h", "http://127.0.0.1:5173/docs?x=1#h", "/api/local-preview/127.0.0.1/5173/docs?x=1#h"] {
            XCTAssertEqual(preview(input)?.absoluteString, "https://wand.test:8443/prefix/api/local-preview/127.0.0.1/5173/docs?x=1#h")
        }
        XCTAssertEqual(preview("http://[::1]:5173/")?.path, "/prefix/api/local-preview/::1/5173")
        let original = try XCTUnwrap(preview("/tmp/index.html"))
        XCTAssertEqual(preview(original.absoluteString), original)
        let raw = try XCTUnwrap(download("https://wand.test:8443/prefix/api/file-raw?path=%2Ftmp%2Fa%2Bb.txt"))
        XCTAssertEqual(URLComponents(url: raw, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value, "/tmp/a+b.txt")
        let formPath = try XCTUnwrap(download("/api/file-raw?path=%2Ftmp%2Fa+b%2Bc.txt"))
        XCTAssertEqual(URLComponents(url: formPath, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "path" }?.value, "/tmp/a b+c.txt")
        let attachment = try XCTUnwrap(WandEndpoint.url(baseURL: base, route: "/api/file-raw", queryItems: [URLQueryItem(name: "path", value: "/tmp/a+b.png")]))
        XCTAssertEqual(attachment.absoluteString, "https://wand.test:8443/prefix/api/file-raw?path=%2Ftmp%2Fa%2Bb.png")
        let root = Data("/tmp/site".utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let nested = try XCTUnwrap(download("/api/local-file/" + root + "/report.pdf?mode=edit&q=a+b%2Bc#page=2"))
        let query = URLComponents(url: nested, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "mode" }?.value, "edit")
        XCTAssertEqual(URLComponents(url: nested, resolvingAgainstBaseURL: false)?.percentEncodedQuery, "mode=edit&q=a+b%2Bc&__wand_file_action=download")
        XCTAssertEqual(query.first { $0.name == "__wand_file_action" }?.value, "download")
        guard case .external(let external) = WandMessageLink.resolve("https://other.test/api/file-raw?path=x", baseURL: base) else { return XCTFail("External URL must not inherit credentials") }
        XCTAssertEqual(external.host, "other.test")
        for input in ["javascript:alert(1)", "//evil.test/a", "file://evil.test/tmp/a", "/api/local-preview/evil.test/80/"] {
            guard case .unavailable = WandMessageLink.resolve(input, baseURL: base) else { XCTFail("Unsafe input accepted: \(input)"); continue }
        }
    }
    func testPreviewAuthenticationAndCSPBoundaries() throws {
        let boundary = MessageLinkBoundary(origin: base)
        XCTAssertTrue(boundary.allows(URL(string: "https://wand.test:8443/prefix/api/local-file/abc/")!))
        for value in ["https://wand.test:8444/prefix/api/file-raw", "https://other.test:8443/prefix/api/file-raw", "https://wand.test:8443/api/file-raw", "https://wand.test:8443/prefix/api/sessions", "https://wand.test:8443/prefix/api/local-file/abc/%252e%252e/%252e%252e/sessions"] {
            XCTAssertFalse(boundary.allows(URL(string: value)!))
        }
        let url = URL(string: "https://wand.test:8443/prefix/api/local-file/abc/sub/index.html")!
        XCTAssertEqual(MessageLinkBoundary.previewScope(url, origin: base), "/prefix/api/local-file/abc/")
        for (csp, expected) in [("sandbox allow-scripts; connect-src 'none'; form-action 'none'", true), ("sandbox allow-scripts allow-same-origin", false), ("default-src 'none'", false)] {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html", "Content-Security-Policy": csp]))
            XCTAssertEqual(MessageLinkBoundary.isolatedHTML(response), expected)
        }
        let pdf = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/pdf"]))
        let download = try XCTUnwrap(MessageLinkBoundary.nonHTMLFileDownload(pdf, origin: base))
        XCTAssertEqual(URLComponents(url: download, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "__wand_file_action" }?.value, "download")
        let loopbackPDF = try XCTUnwrap(preview("http://localhost:5173/report.pdf?q=a+b%2Bc#page=2"))
        let loopbackResponse = try XCTUnwrap(HTTPURLResponse(url: loopbackPDF, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/pdf"]))
        XCTAssertEqual(MessageLinkBoundary.nonHTMLFileDownload(loopbackResponse, origin: base), loopbackPDF)
        let unsafeHTML = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"]))
        XCTAssertNil(MessageLinkBoundary.nonHTMLFileDownload(unsafeHTML, origin: base), "HTML without CSP must not silently fall back to an executable viewer")
        XCTAssertEqual(MessageLinkPreviewModel.safeName("../../a.txt"), ".._.._a.txt")
    }
    func testAttributedMarkdownKeepsRelativeTargetsForSourceResolution() throws {
        let parsed = messageLinkedText("[预览](output/demo.html?x=1#section) [源码](</tmp/my file.txt:12>)")
        let urls = parsed.runs.compactMap { $0.link?.absoluteString }
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(urls[0], "output/demo.html?x=1#section")
        XCTAssertEqual(urls[1], "/tmp/my%20file.txt:12")
    }
    func testInstalledServiceFilesAndIsolatedHTML() async throws {
        guard ProcessInfo.processInfo.environment["WAND_LINK_LIVE"] == "1" else { throw XCTSkip("Opt-in installed-service read-only acceptance") }
        let connection = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".wand/acceptance-connection.json")
        let values = try JSONSerialization.jsonObject(with: Data(contentsOf: connection)) as? [String: String]
        let server = try XCTUnwrap(values?["serverURL"].flatMap(URL.init(string:)))
        let code = try XCTUnwrap(values?["connectionCode"])
        let token = try XCTUnwrap(WandAuth.decodeConnectCode(code)?.token)
        let api = WandAPI(baseURL: server, token: token)
        let context = WandMessageFileContext(sessionID: "92d12f7e-3a03-45d1-842e-036c469d2db3")
        let model = MessageLinkPreviewModel()
        defer { model.close() }
        model.load(WandMessageLink.resolve("output/link-formats-20261027/fixtures/site/index.html?mode=edit#details", baseURL: server, context: context), api: api)
        for _ in 0..<250 {
            if model.error != nil || (!model.loading && model.browser != nil) { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(model.error)
        let browser = try XCTUnwrap(model.browser)
        let navigation = try await browser.evaluateJavaScript("document.querySelector('#nav').textContent") as? String
        XCTAssertEqual(navigation, "?mode=edit#details")
        let counter = try await browser.evaluateJavaScript("document.querySelector('button').click();document.querySelector('#result').value") as? String
        XCTAssertEqual(counter, "1", "The actual isolated HTML form remains interactive")
        let cookiesBlocked = try await browser.evaluateJavaScript("(()=>{try{document.cookie;return false}catch{return true}})()") as? Bool
        XCTAssertEqual(cookiesBlocked, true, "Artifact scripts cannot read Wand cookies")
        model.load(WandMessageLink.resolve("output/link-formats-20261027/fixtures/source.txt", baseURL: server, context: context), api: api)
        for _ in 0..<200 {
            if model.error != nil || model.localFile != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNil(model.error)
        let file = try XCTUnwrap(model.localFile)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("output/link-formats-20261027/fixtures/source.txt")
        XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: fixture))
        model.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "Only this preview's temporary file is cleaned on close")
    }

}
