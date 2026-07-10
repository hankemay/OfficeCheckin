import Foundation
import SwiftData

enum ExportService {
    static var directory: URL {
        let fileManager = FileManager.default
        let besideApp = Bundle.main.bundleURL.deletingLastPathComponent().appending(path: "OfficeCheckin Exports", directoryHint: .isDirectory)
        if (try? fileManager.createDirectory(at: besideApp, withIntermediateDirectories: true)) != nil,
           fileManager.isWritableFile(atPath: besideApp.path) { return besideApp }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "OfficeCheckin/exports", directoryHint: .isDirectory)
    }

    @discardableResult
    static func export(from context: ModelContext? = nil) throws -> URL {
        let modelContext: ModelContext
        if let context { modelContext = context }
        else if let container = try? ModelContainer(for: CheckIn.self, OperationLog.self) { modelContext = ModelContext(container) }
        else { throw ExportError.databaseUnavailable }
        let data = try modelContext.fetch(FetchDescriptor<CheckIn>(sortBy: [SortDescriptor(\.dayKey)]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let latest = directory.appending(path: "OfficeCheckin_Latest.xlsx")
        if FileManager.default.fileExists(atPath: latest.path()) {
            let name = "OfficeCheckin_\(Date.now.formatted(.dateTime.year().month().day().hour().minute().second())).xlsx".replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            try FileManager.default.copyItem(at: latest, to: directory.appending(path: name))
        }
        let sheetRows = data.enumerated().map { index, item in
            "<row r=\"\(index + 2)\"><c r=\"A\(index + 2)\" t=\"inlineStr\"><is><t>\(item.dayKey.xml)</t></is></c><c r=\"B\(index + 2)\" t=\"inlineStr\"><is><t>\(item.checkedInAt.formatted(date: .numeric, time: .standard).xml)</t></is></c><c r=\"C\(index + 2)\" t=\"inlineStr\"><is><t>\(item.ssid.xml)</t></is></c><c r=\"D\(index + 2)\" t=\"inlineStr\"><is><t>\(item.source.xml)</t></is></c></row>"
        }.joined()
        let sheet = "<?xml version=\"1.0\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Date</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>Check-in Time</t></is></c><c r=\"C1\" t=\"inlineStr\"><is><t>Wi-Fi</t></is></c><c r=\"D1\" t=\"inlineStr\"><is><t>Source</t></is></c></row>\(sheetRows)</sheetData></worksheet>"
        let calendar = Calendar.current
        let weekly = Dictionary(grouping: data) { calendar.dateInterval(of: .weekOfYear, for: $0.checkedInAt)?.start ?? $0.checkedInAt }
            .sorted { $0.key < $1.key }
        let weeklyRows = weekly.enumerated().map { index, group in
            let row = index + 2
            let weekStart = group.key.formatted(date: .abbreviated, time: .omitted)
            return "<row r=\"\(row)\"><c r=\"A\(row)\" t=\"inlineStr\"><is><t>\(weekStart.xml)</t></is></c><c r=\"B\(row)\" t=\"inlineStr\"><is><t>\(group.value.count)</t></is></c></row>"
        }.joined()
        let weeklySheet = "<?xml version=\"1.0\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Week Starting</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>Check-ins</t></is></c></row>\(weeklyRows)</sheetData></worksheet>"
        let summaries = QuarterSummary.all(from: data).reversed()
        let summaryRows = summaries.enumerated().map { index, item in
            let row = index + 2
            let average = String(format: "%.1f", item.averagePerWeek)
            return "<row r=\"\(row)\"><c r=\"A\(row)\" t=\"inlineStr\"><is><t>\(item.title)</t></is></c><c r=\"B\(row)\" t=\"inlineStr\"><is><t>\(item.checkInCount)</t></is></c><c r=\"C\(row)\" t=\"inlineStr\"><is><t>\(item.workingDays)</t></is></c><c r=\"D\(row)\" t=\"inlineStr\"><is><t>\(average)</t></is></c><c r=\"E\(row)\" t=\"inlineStr\"><is><t>\(item.minimumCheckIns)</t></is></c></row>"
        }.joined()
        let summarySheet = "<?xml version=\"1.0\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Quarter</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>Check-ins</t></is></c><c r=\"C1\" t=\"inlineStr\"><is><t>Working Days</t></is></c><c r=\"D1\" t=\"inlineStr\"><is><t>Avg / Week</t></is></c><c r=\"E1\" t=\"inlineStr\"><is><t>Minimum Target</t></is></c></row>\(summaryRows)</sheetData></worksheet>"
        let parts = [
            "[Content_Types].xml": "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/><Override PartName=\"/xl/worksheets/sheet2.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/><Override PartName=\"/xl/worksheets/sheet3.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>",
            "_rels/.rels": "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>",
            "xl/workbook.xml": "<?xml version=\"1.0\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Check-ins\" sheetId=\"1\" r:id=\"rId1\"/><sheet name=\"Weekly Summary\" sheetId=\"2\" r:id=\"rId2\"/><sheet name=\"Quarterly Summary\" sheetId=\"3\" r:id=\"rId3\"/></sheets></workbook>",
            "xl/_rels/workbook.xml.rels": "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/><Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet2.xml\"/><Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet3.xml\"/></Relationships>",
            "xl/worksheets/sheet1.xml": sheet,
            "xl/worksheets/sheet2.xml": weeklySheet,
            "xl/worksheets/sheet3.xml": summarySheet
        ]
        try SimpleZip.write(parts, to: latest)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]).filter { $0.lastPathComponent.range(of: "^OfficeCheckin_[0-9]{4}", options: .regularExpression) != nil }.sorted { $0.contentModificationDate < $1.contentModificationDate }
        for old in files.dropLast(2) { try FileManager.default.removeItem(at: old) }
        return latest
    }

    /// A separate audit trail for intentional human changes such as backfills and removals.
    @discardableResult
    static func exportOperations(from context: ModelContext) throws -> URL {
        let logs = try context.fetch(FetchDescriptor<OperationLog>(sortBy: [SortDescriptor(\.performedAt)]))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let latest = directory.appending(path: "OfficeCheckin_Operations_Latest.xlsx")
        let rows = logs.enumerated().map { index, log in
            let row = index + 2
            let timestamp = log.performedAt.formatted(date: .numeric, time: .standard)
            return "<row r=\"\(row)\"><c r=\"A\(row)\" t=\"inlineStr\"><is><t>\(timestamp.xml)</t></is></c><c r=\"B\(row)\" t=\"inlineStr\"><is><t>\(log.action.xml)</t></is></c><c r=\"C\(row)\" t=\"inlineStr\"><is><t>\(log.dayKey.xml)</t></is></c></row>"
        }.joined()
        let sheet = "<?xml version=\"1.0\"?><worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData><row r=\"1\"><c r=\"A1\" t=\"inlineStr\"><is><t>Performed At</t></is></c><c r=\"B1\" t=\"inlineStr\"><is><t>Operation</t></is></c><c r=\"C1\" t=\"inlineStr\"><is><t>Check-in Date</t></is></c></row>\(rows)</sheetData></worksheet>"
        let parts = [
            "[Content_Types].xml": "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/xl/workbook.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml\"/><Override PartName=\"/xl/worksheets/sheet1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/></Types>",
            "_rels/.rels": "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"xl/workbook.xml\"/></Relationships>",
            "xl/workbook.xml": "<?xml version=\"1.0\"?><workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><sheets><sheet name=\"Operations\" sheetId=\"1\" r:id=\"rId1\"/></sheets></workbook>",
            "xl/_rels/workbook.xml.rels": "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet1.xml\"/></Relationships>",
            "xl/worksheets/sheet1.xml": sheet
        ]
        try SimpleZip.write(parts, to: latest)
        return latest
    }
}

enum ExportError: LocalizedError { case databaseUnavailable; var errorDescription: String? { "The local check-in database is unavailable." } }

private extension URL { var contentModificationDate: Date { (try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast } }
private extension String { var xml: String { replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") } }

/// Minimal ZIP writer using the uncompressed ZIP format required by .xlsx packages.
private enum SimpleZip {
    static func write(_ files: [String: String], to url: URL) throws {
        var archive = Data(); var central = Data(); var offset: UInt32 = 0
        for (name, text) in files.sorted(by: { $0.key < $1.key }) {
            let fileName = Data(name.utf8), payload = Data(text.utf8), crc = CRC32.value(payload)
            archive.u32(0x04034b50); archive.u16(20); archive.u16(0); archive.u16(0); archive.u16(0); archive.u16(0)
            archive.u32(crc); archive.u32(UInt32(payload.count)); archive.u32(UInt32(payload.count)); archive.u16(UInt16(fileName.count)); archive.u16(0)
            archive.append(fileName); archive.append(payload)
            central.u32(0x02014b50); central.u16(20); central.u16(20); central.u16(0); central.u16(0); central.u16(0); central.u16(0)
            central.u32(crc); central.u32(UInt32(payload.count)); central.u32(UInt32(payload.count)); central.u16(UInt16(fileName.count)); central.u16(0); central.u16(0); central.u16(0); central.u16(0); central.u32(0); central.u32(offset)
            central.append(fileName); offset = UInt32(archive.count)
        }
        let centralOffset = UInt32(archive.count); archive.append(central)
        archive.u32(0x06054b50); archive.u16(0); archive.u16(0); archive.u16(UInt16(files.count)); archive.u16(UInt16(files.count)); archive.u32(UInt32(central.count)); archive.u32(centralOffset); archive.u16(0)
        try archive.write(to: url, options: .atomic)
    }
}

private extension Data {
    mutating func u16(_ value: UInt16) { append(contentsOf: [UInt8(value & 0xff), UInt8(value >> 8)]) }
    mutating func u32(_ value: UInt32) { append(contentsOf: [UInt8(value & 0xff), UInt8((value >> 8) & 0xff), UInt8((value >> 16) & 0xff), UInt8(value >> 24)]) }
}

private enum CRC32 {
    static func value(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data { crc ^= UInt32(byte); for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 } }
        return crc ^ 0xffffffff
    }
}
