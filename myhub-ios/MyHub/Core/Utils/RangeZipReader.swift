import Foundation
import Compression

/// 基于 Range 读取的 ZIP 解析器（漫画封面 / 后续漫画阅读器复用）：
/// 只对归档做 3 次左右 Range 请求（尾部 EOCD → 中央目录 → 目标条目），不整包下载。
/// 支持存储（stored）与 deflate 压缩条目的解压。
struct RangeZipReader {
    typealias RangeReader = (Range<Int64>) async throws -> Data

    struct Entry {
        let name: String
        let compressedSize: Int64
        let uncompressedSize: Int64
        let compressionMethod: UInt16   // 0 = stored, 8 = deflate
        let localHeaderOffset: Int64

        var isDirectory: Bool { name.hasSuffix("/") }
    }

    private let read: RangeReader
    private let totalSize: Int64

    /// - Parameters:
    ///   - totalSize: 归档总字节数（FileEntry.size）
    ///   - reader: 按字节区间读取数据的闭包（适配器 readStream 收集）
    init(totalSize: Int64, reader: @escaping RangeReader) {
        self.totalSize = totalSize
        self.read = reader
    }

    // MARK: - 中央目录

    /// 读取全部条目（EOCD → 中央目录）
    func entries() async throws -> [Entry] {
        guard totalSize > 22 else { throw ZipError.malformed }
        // EOCD 定长 22 字节 + 最长 65535 字节注释；从尾部窗口内搜索签名
        let window = min(totalSize, 22 + 65535)
        let tail = try await read((totalSize - window)..<totalSize)
        guard let eocdOffset = Self.locateEOCD(in: tail) else { throw ZipError.malformed }

        let eocd = Data(tail[eocdOffset...])   // 转为 0 起始索引的 Data 便于解析
        var entryCount = Int(Self.uint16(eocd, at: 10))
        var cdSize = Int64(Self.uint32(eocd, at: 12))
        var cdOffset = Int64(Self.uint32(eocd, at: 16))

        // ZIP64（>4GB 或 >65535 条目）：常规字段为哨兵值时改读 ZIP64 EOCD
        //（locator 位于 EOCD 前 20 字节；仅大小/偏移为哨兵却缺记录时才算损坏）
        if entryCount == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
            if let zip64 = try await readZip64EOCD(
                eocdGlobalOffset: totalSize - window + Int64(eocdOffset)
            ) {
                entryCount = Int(clamping: zip64.entryCount)
                cdSize = zip64.cdSize
                cdOffset = zip64.cdOffset
            } else if cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF {
                throw ZipError.malformed
            }
            // entryCount 恰为 0xFFFF 且无 ZIP64 记录：普通 ZIP 合法值，按原值继续
        }
        guard entryCount > 0, cdSize > 0 else { return [] }

        let cdRange = cdOffset..<(cdOffset + cdSize)
        let cd = try await read(cdRange)

        var result: [Entry] = []
        result.reserveCapacity(min(entryCount, 8192))
        var cursor = 0
        while cursor + 46 <= cd.count {
            guard Self.uint32(cd, at: cursor) == 0x02014B50 else { break }   // central file header
            let method = Self.uint16(cd, at: cursor + 10)
            let compressed32 = Self.uint32(cd, at: cursor + 20)
            let uncompressed32 = Self.uint32(cd, at: cursor + 24)
            let nameLength = Int(Self.uint16(cd, at: cursor + 28))
            let extraLength = Int(Self.uint16(cd, at: cursor + 30))
            let commentLength = Int(Self.uint16(cd, at: cursor + 32))
            let localOffset32 = Self.uint32(cd, at: cursor + 42)
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLength
            guard nameEnd <= cd.count else { break }
            let nameData = cd[nameStart..<nameEnd]
            // ZIP64 条目：常规字段为哨兵值时，从扩展字段（header id 0x0001）取 64 位真值
            var compressed = Int64(compressed32)
            var uncompressed = Int64(uncompressed32)
            var localOffset = Int64(localOffset32)
            if compressed32 == 0xFFFF_FFFF || uncompressed32 == 0xFFFF_FFFF || localOffset32 == 0xFFFF_FFFF {
                let extraEnd = min(nameEnd + extraLength, cd.count)
                let zip64 = Self.zip64ExtraValues(
                    cd, start: nameEnd, end: extraEnd,
                    needUncompressed: uncompressed32 == 0xFFFF_FFFF,
                    needCompressed: compressed32 == 0xFFFF_FFFF,
                    needOffset: localOffset32 == 0xFFFF_FFFF
                )
                if let value = zip64.uncompressed { uncompressed = value }
                if let value = zip64.compressed { compressed = value }
                if let value = zip64.localOffset { localOffset = value }
            }
            // ZIP 文件名可能为 UTF-8（通用标志位 bit 11）或 CP437/GBK；优先 UTF-8，回退 GB18030
            let flag = Self.uint16(cd, at: cursor + 8)
            let name = Self.decodeName(Data(nameData), utf8Flag: (flag & 0x0800) != 0)
            result.append(Entry(
                name: name,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                compressionMethod: method,
                localHeaderOffset: localOffset
            ))
            cursor = nameEnd + extraLength + commentLength
        }
        return result
    }

    /// 读取并解压条目数据
    func extract(_ entry: Entry) async throws -> Data {
        // 本地头：签名 4 + 版本 2 + 标志 2 + 方法 2 + 时间 4 + CRC 4 + 压缩 4 + 原始 4 + 名长 2 + 扩展长 2
        let header = try await read(entry.localHeaderOffset..<(entry.localHeaderOffset + 30))
        guard Self.uint32(header, at: 0) == 0x04034B50 else { throw ZipError.malformed }
        let nameLength = Int64(Self.uint16(header, at: 26))
        let extraLength = Int64(Self.uint16(header, at: 28))
        let dataStart = entry.localHeaderOffset + 30 + nameLength + extraLength
        let compressed = try await read(dataStart..<(dataStart + entry.compressedSize))

        switch entry.compressionMethod {
        case 0:   // stored
            return compressed
        case 8:   // deflate（raw，Compression 框架解码）
            guard let data = Self.inflate(compressed, uncompressedSize: Int(entry.uncompressedSize)) else {
                throw ZipError.decompressFailed
            }
            return data
        default:
            throw ZipError.unsupportedMethod(entry.compressionMethod)
        }
    }

    /// 归档内第一个图片条目（自然序），供漫画封面取页
    func firstImageEntry() async throws -> Entry? {
        let images = try await entries()
            .filter { !$0.isDirectory && ["jpg", "jpeg", "png", "gif", "webp", "bmp"].contains(StoragePath.ext(of: $0.name)) }
        return images.sorted { $0.name.naturalCompare($1.name) == .orderedAscending }.first
    }

    // MARK: - 内部

    enum ZipError: Error {
        case malformed
        case decompressFailed
        case unsupportedMethod(UInt16)
    }

    // MARK: - ZIP64

    private struct Zip64EOCD {
        let entryCount: Int64
        let cdSize: Int64
        let cdOffset: Int64
    }

    private struct Zip64Extra {
        var uncompressed: Int64?
        var compressed: Int64?
        var localOffset: Int64?
    }

    /// 读取 ZIP64 EOCD 记录：locator（签名 0x07064B50）位于 EOCD 前 20 字节，
    /// 记录（签名 0x06064B50）携带 64 位条目数与中央目录偏移/大小；不存在则返回 nil。
    private func readZip64EOCD(eocdGlobalOffset: Int64) async throws -> Zip64EOCD? {
        guard eocdGlobalOffset >= 20 else { return nil }
        let locator = try await read((eocdGlobalOffset - 20)..<eocdGlobalOffset)
        guard locator.count >= 20, Self.uint32(locator, at: 0) == 0x07064B50 else { return nil }
        let recordOffset = Int64(bitPattern: Self.uint64(locator, at: 8))
        guard recordOffset >= 0, recordOffset + 56 <= totalSize else { return nil }
        let record = try await read(recordOffset..<(recordOffset + 56))
        guard record.count >= 56, Self.uint32(record, at: 0) == 0x06064B50 else { return nil }
        return Zip64EOCD(
            entryCount: Int64(bitPattern: Self.uint64(record, at: 32)),
            cdSize: Int64(bitPattern: Self.uint64(record, at: 40)),
            cdOffset: Int64(bitPattern: Self.uint64(record, at: 48))
        )
    }

    /// 解析中央目录条目的 ZIP64 扩展字段（header id 0x0001）：按需依次为
    /// 原始大小 / 压缩大小 / 本地头偏移（各 8 字节，仅哨兵字段才有对应值）。
    private static func zip64ExtraValues(
        _ data: Data, start: Int, end: Int,
        needUncompressed: Bool, needCompressed: Bool, needOffset: Bool
    ) -> Zip64Extra {
        var result = Zip64Extra()
        var cursor = start
        while cursor + 4 <= end {
            let headerID = uint16(data, at: cursor)
            let bodySize = Int(uint16(data, at: cursor + 2))
            let body = cursor + 4
            if headerID == 0x0001 {
                var pointer = body
                if needUncompressed, pointer + 8 <= end {
                    result.uncompressed = Int64(bitPattern: uint64(data, at: pointer))
                    pointer += 8
                }
                if needCompressed, pointer + 8 <= end {
                    result.compressed = Int64(bitPattern: uint64(data, at: pointer))
                    pointer += 8
                }
                if needOffset, pointer + 8 <= end {
                    result.localOffset = Int64(bitPattern: uint64(data, at: pointer))
                    pointer += 8
                }
                break
            }
            cursor = body + bodySize
        }
        return result
    }

    private static func locateEOCD(in data: Data) -> Int? {
        let signature: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        guard data.count >= 22 else { return nil }
        var index = data.count - 22
        while index >= 0 {
            if data[index] == signature[0], data[index + 1] == signature[1],
               data[index + 2] == signature[2], data[index + 3] == signature[3] {
                return index
            }
            index -= 1
        }
        return nil
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }

    private static func uint64(_ data: Data, at offset: Int) -> UInt64 {
        (UInt64(uint32(data, at: offset + 4)) << 32) | UInt64(uint32(data, at: offset))
    }

    private static func decodeName(_ data: Data, utf8Flag: Bool) -> String {
        if utf8Flag, let name = String(data: data, encoding: .utf8) { return name }
        if let name = String(data: data, encoding: .utf8) { return name }
        // 回退：GB18030（中文压缩包常见）→ CP437
        if let name = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))) {
            return name
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// raw deflate 解压（COMPRESSION_ZLIB 处理 deflate 流，与 ZIP method 8 对应）
    private static func inflate(_ data: Data, uncompressedSize: Int) -> Data? {
        guard uncompressedSize > 0, uncompressedSize < 512 * 1024 * 1024 else { return nil }
        return data.withUnsafeBytes { source in
            guard let sourceBase = source.baseAddress else { return nil }
            var destination = Data(count: uncompressedSize)
            let decoded = destination.withUnsafeMutableBytes { buffer in
                compression_decode_buffer(
                    buffer.baseAddress!, uncompressedSize,
                    sourceBase, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
            guard decoded > 0 else { return nil }
            if decoded < uncompressedSize { destination = destination.prefix(decoded) }
            return destination
        }
    }
}
