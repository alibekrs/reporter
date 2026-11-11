import Foundation

/// Недельный отчёт в Word — как reports.build_docx на сервере: шапка «Филиал / Дата /
/// Ответственный» и таблица из шести колонок (Grid Table 4 — Accent 1), A4.
enum Docx {
    private static let cols = ["Дата", "№", "Сотрудник / объект", "Описание обращения",
                               "Выполненные действия", "Результат"]
    private static let widths = [796, 490, 1934, 2030, 2058, 2042]          // твипы, как в шаблоне
    private static let monthsGen = ["января", "февраля", "марта", "апреля", "мая", "июня", "июля",
                                    "августа", "сентября", "октября", "ноября", "декабря"]

    static func week(branch: String, responsible: String, monday: Date, entries: [Entry]) -> Data {
        let cal = Calendar(identifier: .gregorian)
        let fri = cal.date(byAdding: .day, value: 4, to: monday)!
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "dd.MM.yyyy"
        var body = line("Филиал: ", branch) + line("Дата: ", f.string(from: monday) + "-" + f.string(from: fri))
            + line("Ответственный: ", responsible) + "<w:p>\(noSpace)</w:p>"

        let borders = ["top", "left", "bottom", "right", "insideH", "insideV"]
            .map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"8EAADB\"/>" }.joined()
        body += "<w:tbl><w:tblPr><w:tblW w:w=\"\(widths.reduce(0, +))\" w:type=\"dxa\"/>"
            + "<w:tblBorders>\(borders)</w:tblBorders><w:tblLayout w:type=\"fixed\"/></w:tblPr><w:tblGrid>"
            + widths.map { "<w:gridCol w:w=\"\($0)\"/>" }.joined() + "</w:tblGrid>"
        body += "<w:tr><w:trPr><w:tblHeader/></w:trPr>"
            + cols.enumerated().map { cell($1, col: $0, fill: "4472C4", header: true) }.joined() + "</w:tr>"
        for (i, e) in entries.enumerated() {
            let d = Dates.parse(e.date)
            let values = ["\(cal.component(.day, from: d)) \(monthsGen[cal.component(.month, from: d) - 1])",
                          String(i + 1), e.employee ?? "", e.description ?? "", e.actions ?? "", e.result ?? ""]
            let fill = (i + 1) % 2 == 0 ? "D9E2F3" : nil                    // чётные строки — полосой
            body += "<w:tr>" + values.enumerated().map { cell($1, col: $0, fill: fill, header: false) }.joined() + "</w:tr>"
        }
        body += "</w:tbl>"

        let document = xmlHead + "<w:document xmlns:w=\"\(ns)\"><w:body>\(body)"
            + "<w:sectPr><w:pgSz w:w=\"11906\" w:h=\"16838\"/>"
            + "<w:pgMar w:top=\"1134\" w:right=\"850\" w:bottom=\"1134\" w:left=\"1701\" w:header=\"708\" w:footer=\"708\" w:gutter=\"0\"/>"
            + "</w:sectPr></w:body></w:document>"
        let styles = xmlHead + "<w:styles xmlns:w=\"\(ns)\"><w:docDefaults><w:rPrDefault><w:rPr>"
            + "<w:rFonts w:ascii=\"Calibri\" w:hAnsi=\"Calibri\" w:cs=\"Calibri\" w:eastAsia=\"Calibri\"/>"
            + "<w:sz w:val=\"24\"/><w:szCs w:val=\"24\"/><w:lang w:val=\"ru-RU\"/></w:rPr></w:rPrDefault>"
            + "<w:pPrDefault><w:pPr><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault>"
            + "</w:docDefaults></w:styles>"
        let types = xmlHead + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
            + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
            + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
            + "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
            + "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>"
            + "</Types>"
        let rels = xmlHead + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
            + "</Relationships>"
        let docRels = xmlHead + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
            + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
            + "</Relationships>"
        return Zip.stored([("[Content_Types].xml", types), ("_rels/.rels", rels),
                           ("word/document.xml", document), ("word/_rels/document.xml.rels", docRels),
                           ("word/styles.xml", styles)].map { ($0.0, Data($0.1.utf8)) })
    }

    static func fileName(monday: Date) -> String {
        let fri = Calendar(identifier: .gregorian).date(byAdding: .day, value: 4, to: monday)!
        let a = DateFormatter(), b = DateFormatter()
        a.locale = Locale(identifier: "en_US_POSIX"); a.dateFormat = "dd.MM"
        b.locale = Locale(identifier: "en_US_POSIX"); b.dateFormat = "dd.MM.yyyy"
        return "Отчёт_\(a.string(from: monday))-\(b.string(from: fri)).docx"
    }

    private static let ns = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
    private static let xmlHead = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    private static let noSpace = "<w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/></w:pPr>"

    private static func line(_ label: String, _ value: String) -> String {
        "<w:p>\(noSpace)<w:r><w:rPr><w:b/></w:rPr>\(text(label))</w:r><w:r>\(text(value))</w:r></w:p>"
    }

    private static func cell(_ value: String, col: Int, fill: String?, header: Bool) -> String {
        let shd = fill.map { "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\($0)\"/>" } ?? ""
        let jc = col == 1 ? "<w:jc w:val=\"center\"/>" : ""
        let rPr = header ? "<w:rPr><w:b/><w:color w:val=\"FFFFFF\"/></w:rPr>" : ""
        return "<w:tc><w:tcPr><w:tcW w:w=\"\(widths[col])\" w:type=\"dxa\"/>\(shd)<w:vAlign w:val=\"center\"/></w:tcPr>"
            + "<w:p><w:pPr><w:spacing w:before=\"0\" w:after=\"0\"/>\(jc)</w:pPr><w:r>\(rPr)\(text(value))</w:r></w:p></w:tc>"
    }

    /// Текст прогона: спецсимволы XML экранированы, переносы строк — <w:br/>.
    /// Экранирует Xlsx.esc: он же выбрасывает управляющие символы (вставка из Word приносит U+000B),
    /// с которыми Word считает файл повреждённым.
    private static func text(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
            .map { "<w:t xml:space=\"preserve\">\(Xlsx.esc(String($0)))</w:t>" }
            .joined(separator: "<w:br/>")
    }
}

/// ZIP без сжатия (stored) — Word такие файлы открывает; сжатие для пары килобайт не нужно.
enum Zip {
    static func stored(_ files: [(String, Data)]) -> Data {
        var out = Data(), central = Data()
        for (name, data) in files {
            let n = Data(name.utf8), crc = crc32(data), size = UInt32(data.count), offset = UInt32(out.count)
            // локальный заголовок: подпись, версия, флаг UTF-8, без сжатия, время 0, дата 01.01.1980
            put32(&out, 0x0403_4b50); put16(&out, 20); put16(&out, 0x0800); put16(&out, 0)
            put16(&out, 0); put16(&out, 0x21); put32(&out, crc); put32(&out, size); put32(&out, size)
            put16(&out, UInt16(n.count)); put16(&out, 0)
            out.append(n); out.append(data)
            // запись центрального каталога
            put32(&central, 0x0201_4b50); put16(&central, 20); put16(&central, 20); put16(&central, 0x0800)
            put16(&central, 0); put16(&central, 0); put16(&central, 0x21); put32(&central, crc)
            put32(&central, size); put32(&central, size); put16(&central, UInt16(n.count))
            put16(&central, 0); put16(&central, 0); put16(&central, 0); put16(&central, 0)
            put32(&central, 0); put32(&central, offset)
            central.append(n)
        }
        let cdOffset = UInt32(out.count), cdSize = UInt32(central.count)
        out.append(central)
        put32(&out, 0x0605_4b50); put16(&out, 0); put16(&out, 0)
        put16(&out, UInt16(files.count)); put16(&out, UInt16(files.count))
        put32(&out, cdSize); put32(&out, cdOffset); put16(&out, 0)
        return out
    }

    private static func put16(_ d: inout Data, _ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
    private static func put32(_ d: inout Data, _ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
