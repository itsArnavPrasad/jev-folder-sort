import AppKit
import CoreServices
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// What the model gets to see about one file. No path, only the name.
public struct FileState: Codable, Equatable, Sendable {
    public var name: String
    public var ext: String
    public var kind: String?
    public var contentType: String?
    public var whereFrom: [String]?
    public var title: String?
    public var authors: [String]?
    public var size: Int64?
    public var text: String?

    enum CodingKeys: String, CodingKey {
        case name, ext, kind, title, authors, size, text
        case contentType = "content_type"
        case whereFrom = "where_from"
    }
}

/// Builds a `FileState`: Spotlight metadata plus the first N KB of text.
public struct Extractor: Sendable {
    public var textLimitBytes: Int

    public init(textLimitKB: Int) {
        textLimitBytes = max(0, textLimitKB) * 1024
    }

    static let richTextExtensions: Set<String> = ["rtf", "rtfd", "doc", "docx", "odt", "wordml"]
    static let plainTextExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "json", "jsonl", "yaml", "yml", "toml", "xml", "html", "htm",
        "py", "js", "ts", "tsx", "jsx", "swift", "go", "rs", "rb", "java", "kt", "c", "h", "cpp", "hpp", "m",
        "sh", "zsh", "sql", "graphql", "env", "ini", "conf", "cfg", "log", "tex", "ics", "ipynb", "css", "scss",
    ]

    public func extract(path: String) -> FileState {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        var state = FileState(name: name, ext: ext)

        if let item = MDItemCreateWithURL(nil, url as CFURL) {
            state.kind = MDItemCopyAttribute(item, kMDItemKind) as? String
            state.contentType = MDItemCopyAttribute(item, kMDItemContentType) as? String
            state.whereFrom = (MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String])?.filter { !$0.isEmpty }
            state.title = MDItemCopyAttribute(item, kMDItemTitle) as? String
            state.authors = MDItemCopyAttribute(item, kMDItemAuthors) as? [String]
        }
        if state.contentType == nil {
            state.contentType = UTType(filenameExtension: ext)?.identifier
        }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path) {
            state.size = (attrs[.size] as? NSNumber)?.int64Value
        }
        if textLimitBytes > 0 {
            state.text = text(url: url, ext: ext, contentType: state.contentType)
        }
        if state.whereFrom?.isEmpty == true { state.whereFrom = nil }
        // Spotlight falls back to the file name when a document has no title.
        if let t = state.title, t == name || t == url.deletingPathExtension().lastPathComponent { state.title = nil }
        return state
    }

    func text(url: URL, ext: String, contentType: String?) -> String? {
        let raw: String?
        if ext == "pdf" {
            raw = pdfText(url)
        } else if Self.richTextExtensions.contains(ext) {
            raw = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        } else if Self.plainTextExtensions.contains(ext) || isText(contentType) {
            raw = plainText(url)
        } else {
            raw = nil
        }
        guard let raw else { return nil }
        let trimmed = String(decoding: raw.utf8.prefix(textLimitBytes), as: UTF8.self)
        let collapsed = trimmed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    private func isText(_ contentType: String?) -> Bool {
        guard let id = contentType, let t = UTType(id) else { return false }
        return t.conforms(to: .text) || t.conforms(to: .sourceCode)
    }

    private func plainText(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: textLimitBytes), !data.isEmpty else { return nil }
        // Binary files masquerading as text: bail if there are NUL bytes.
        if data.contains(0) { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private func pdfText(_ url: URL) -> String? {
        guard let doc = PDFDocument(url: url) else { return nil }
        var out = ""
        for i in 0..<min(doc.pageCount, 20) {
            out += (doc.page(at: i)?.string ?? "") + "\n"
            if out.utf8.count >= textLimitBytes { break }
        }
        return out
    }
}
