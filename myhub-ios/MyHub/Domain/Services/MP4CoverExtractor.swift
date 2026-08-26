import Foundation
import UIKit
import AVFoundation
import VideoToolbox

/// mp4 首帧提取结果
struct MP4CoverResult {
    let image: UIImage?
    let duration: Double?
}

private extension Data {
    func uint8(_ i: Int) -> UInt8 { guard i >= 0, i < count else { return 0 }; return self[startIndex + i] }
    func uint16BE(_ i: Int) -> UInt16 { UInt16(uint8(i)) << 8 | UInt16(uint8(i + 1)) }
    func uint32BE(_ i: Int) -> UInt32 {
        UInt32(uint8(i)) << 24 | UInt32(uint8(i + 1)) << 16 | UInt32(uint8(i + 2)) << 8 | UInt32(uint8(i + 3))
    }
    func uint64BE(_ i: Int) -> UInt64 { UInt64(uint32BE(i)) << 32 | UInt64(uint32BE(i + 4)) }
    func fourCC(_ i: Int) -> String {
        String(bytes: [uint8(i), uint8(i + 1), uint8(i + 2), uint8(i + 3)], encoding: .ascii) ?? ""
    }
}

private struct MP4Box {
    let type: String
    let payloadStart: Int64
    let boxEnd: Int64
    var payloadRange: Range<Int64> { payloadStart..<boxEnd }
}

enum MP4CoverExtractor {
    typealias Reader = (Range<Int64>) async throws -> Data

    static func extract(fileSize: Int64, read: @escaping Reader) async throws -> MP4CoverResult {
        guard let moov = try await locateMoov(fileSize: fileSize, read: read) else {
            throw NSError(domain: "MP4Cover", code: 1, userInfo: [NSLocalizedDescriptionKey: "moov not found"])
        }
        // moov 可能较大（含大量 sample 表），限流读，首帧/covr 通常在前段
        let moovData = try await read(moov.payloadRange)
        let moovBytes = Array(moovData)

        var cover: UIImage? = nil
        var duration: Double? = nil
        // 优先内嵌封面（零解码成本）
        if let covr = extractCovr(moovBytes: moovBytes) {
            cover = covr
        }
        // 时长来自 mvhd
        duration = parseDuration(moovBytes: moovBytes)
        // 无内嵌封面则解码首帧。当前仅支持 avcC(H.264)/hevC(HEVC)，AV1/VP9 会抛 unsupported codec，
        // 需由上层回退 VLC 抽帧（ffmpeg 支持 AV1/VP9 解码，能拿到封面），不能用 try? 吞掉 ——
        // 否则 AV1 视频直接变成「无封面」占位，这正是「视频封面完全不加载」的回归根因。
        if cover == nil {
            cover = try await decodeFirstFrame(moovBytes: moovBytes, moovPayloadStart: moov.payloadStart, read: read)
        }
        return MP4CoverResult(image: cover, duration: duration)
    }

    // MARK: 定位 moov

    private static func locateMoov(fileSize: Int64, read: Reader) async throws -> MP4Box? {
        var offset: Int64 = 0
        for _ in 0..<64 {
            guard let box = try await readBoxHeader(at: offset, fileSize: fileSize, read: read) else { break }
            if box.type == "moov" { return box }
            if box.boxEnd <= offset { break } // 防死循环
            offset = box.boxEnd
        }
        return nil
    }

    private static func readBoxHeader(at offset: Int64, fileSize: Int64, read: Reader) async throws -> MP4Box? {
        guard offset + 8 <= fileSize else { return nil }
        let head = try await read(offset..<(offset + 8))
        guard head.count == 8 else { return nil }
        let size32 = head.uint32BE(0)
        let type = head.fourCC(4)
        var headerSize: Int64 = 8
        var boxSize: Int64 = Int64(size32)
        if size32 == 1 {
            guard offset + 16 <= fileSize else { return nil }
            let ext = try await read((offset + 8)..<(offset + 16))
            guard ext.count == 8 else { return nil }
            boxSize = Int64(ext.uint64BE(0))
            headerSize = 16
        } else if size32 == 0 {
            boxSize = fileSize - offset
        }
        return MP4Box(type: type, payloadStart: offset + headerSize, boxEnd: offset + boxSize)
    }

    // MARK: 内嵌封面（covr）

    private static func extractCovr(moovBytes: [UInt8]) -> UIImage? {
        guard let covr = findBox("covr", in: moovBytes, base: 0) else { return nil }
        // covr 内嵌 data box：type(4) + locale(4) + 图片数据
        guard let dataBox = findBox("data", in: moovBytes, base: Int(covr.payloadStart), limit: Int(covr.boxEnd)) else { return nil }
        let start = Int(dataBox.payloadStart) + 8
        let end = Int(dataBox.boxEnd)
        guard start < end, end <= moovBytes.count else { return nil }
        return UIImage(data: Data(moovBytes[start..<end]))
    }

    private static func parseDuration(moovBytes: [UInt8]) -> Double? {
        guard let mvhd = findBox("mvhd", in: moovBytes, base: 0) else { return nil }
        let p = Int(mvhd.payloadStart)
        let bytes = moovBytes
        guard p + 4 <= bytes.count else { return nil }
        let version = bytes[p]
        let timescale: UInt64
        let duration: UInt64
        if version == 1 {
            // mvhd v1：version(1)+flags(3)+creation(8)+modification(8)+timescale(4)+duration(8)
            guard p + 32 <= bytes.count else { return nil }
            timescale = UInt64(Data(bytes[p + 20..<p + 24]).uint32BE(0))
            duration = Data(bytes[p + 24..<p + 32]).uint64BE(0)
        } else {
            // mvhd v0：version(1)+flags(3)+creation(4)+modification(4)+timescale(4)+duration(4)
            guard p + 20 <= bytes.count else { return nil }
            timescale = UInt64(Data(bytes[p + 12..<p + 16]).uint32BE(0))
            duration = UInt64(Data(bytes[p + 16..<p + 20]).uint32BE(0))
        }
        guard timescale > 0 else { return nil }
        return Double(duration) / Double(timescale)
    }

    // MARK: 首帧定位与解码

    private static func decodeFirstFrame(moovBytes: [UInt8], moovPayloadStart: Int64, read: Reader) async throws -> UIImage? {
        // 找 video trak（trak 内 hdlr 为 vide）
        guard let videoTrak = try findVideoTrak(moovBytes: moovBytes) else { return nil }
        guard let stbl = findBox("stbl", in: moovBytes, base: Int(videoTrak.payloadStart)) else { return nil }
        let stblBase = Int(stbl.payloadStart)

        // stsd -> codec 配置（avcC/hevC）
        guard let stsd = findBox("stsd", in: moovBytes, base: stblBase) else { return nil }
        let codec = try parseCodecConfig(stsd, moovBytes: moovBytes)

        // sample 表（stsz/stsc/stco）用于定位任意 sample 的 offset/size
        guard let tables = SampleTables(moovBytes: moovBytes, stblBase: stblBase), tables.sampleCount >= 1 else { return nil }

        // 首选第一个关键帧：stss 首条目。经 ffmpeg 转码/裁剪的视频，首 sample 往往不是 IDR
        // 关键帧（首 GOP 可能以 SEI/P/B 帧开头），直接取首 sample 会让 VideoToolbox 解码失败，
        // 进而回退 VLC —— 而 moov 后置时 VLC 会读整个文件在 NAS 上超时，封面永久占位。
        // 这里定位到真正的 IDR 关键帧再解码。
        var target = 0
        if let stss = findBox("stss", in: moovBytes, base: stblBase) {
            let p = Int(stss.payloadStart)
            if p + 12 <= moovBytes.count {
                let count = Int(Data(moovBytes[p + 4..<p + 8]).uint32BE(0))
                if count >= 1 {
                    let firstSync = Int(Data(moovBytes[p + 8..<p + 12]).uint32BE(0)) // 1-based sample 序号
                    if firstSync >= 1 { target = firstSync - 1 }
                }
            }
        }

        // 依次尝试：关键帧 → 向后若干 sample → 首 sample，首个能解码出图的即返回
        var candidates = [target]
        for i in 1..<min(16, tables.sampleCount) {
            let next = (target + i) % tables.sampleCount
            if !candidates.contains(next) { candidates.append(next) }
        }
        for idx in candidates {
            guard let loc = tables.sampleLocation(idx), loc.size > 0 else { continue }
            let frameData = try await read(loc.offset..<(loc.offset + Int64(loc.size)))
            guard frameData.count == loc.size else { continue }
            if let image = await decodeFrame(codec: codec, frameData: frameData) {
                return image
            }
        }
        return nil
    }

    /// 视频 sample 定位表：解析 stsz（sample 大小）+ stsc（sample→chunk）+ stco/co64（chunk 偏移），
    /// 支持定位任意 sample 的字节偏移与大小（用于取关键帧而非首 sample）。
    private struct SampleTables {
        let sampleCount: Int
        private let defaultSize: Int
        private let sizes: [Int]?            // defaultSize == 0 时为每个 sample 的大小
        private let stscEntries: [(firstChunk: Int, samplesPerChunk: Int)]
        private let chunkOffsets: [Int64]

        init?(moovBytes: [UInt8], stblBase: Int) {
            let bytes = moovBytes
            // stsz
            guard let stsz = MP4CoverExtractor.findBox("stsz", in: bytes, base: stblBase) else { return nil }
            let p = Int(stsz.payloadStart)
            guard p + 12 <= bytes.count else { return nil }
            let dSize = Int(Data(bytes[p + 4..<p + 8]).uint32BE(0))
            let count = Int(Data(bytes[p + 8..<p + 12]).uint32BE(0))
            guard count >= 1 else { return nil }
            var sizes: [Int]? = nil
            if dSize == 0 {
                var arr = [Int](repeating: 0, count: count)
                var q = p + 12
                for i in 0..<count {
                    guard q + 4 <= bytes.count else { return nil }
                    arr[i] = Int(Data(bytes[q..<q + 4]).uint32BE(0))
                    q += 4
                }
                sizes = arr
            }
            // stsc
            guard let stsc = MP4CoverExtractor.findBox("stsc", in: bytes, base: stblBase) else { return nil }
            let sp = Int(stsc.payloadStart)
            guard sp + 8 <= bytes.count else { return nil }
            let entryCount = Int(Data(bytes[sp + 4..<sp + 8]).uint32BE(0))
            guard entryCount >= 1 else { return nil }
            var entries: [(firstChunk: Int, samplesPerChunk: Int)] = []
            for i in 0..<entryCount {
                let q = sp + 8 + i * 12
                guard q + 12 <= bytes.count else { return nil }
                let fc = Int(Data(bytes[q..<q + 4]).uint32BE(0))
                let spc = Int(Data(bytes[q + 4..<q + 8]).uint32BE(0))
                entries.append((fc, spc))
            }
            // stco/co64
            let coBox = MP4CoverExtractor.findBox("stco", in: bytes, base: stblBase)
                ?? MP4CoverExtractor.findBox("co64", in: bytes, base: stblBase)
            guard let coBox else { return nil }
            let isCo64 = coBox.type == "co64"
            let cp = Int(coBox.payloadStart)
            guard cp + 8 <= bytes.count else { return nil }
            let chunkCount = Int(Data(bytes[cp + 4..<cp + 8]).uint32BE(0))
            guard chunkCount >= 1 else { return nil }
            var offsets: [Int64] = []
            for i in 0..<chunkCount {
                let q = cp + 8 + i * (isCo64 ? 8 : 4)
                guard q + (isCo64 ? 8 : 4) <= bytes.count else { return nil }
                if isCo64 {
                    offsets.append(Int64(Data(bytes[q..<q + 8]).uint64BE(0)))
                } else {
                    offsets.append(Int64(Data(bytes[q..<q + 4]).uint32BE(0)))
                }
            }
            self.sampleCount = count
            self.defaultSize = dSize
            self.sizes = sizes
            self.stscEntries = entries
            self.chunkOffsets = offsets
        }

        func size(of index: Int) -> Int {
            if let sizes { return sizes[index] }
            return defaultSize
        }

        func samplesPerChunk(forChunk chunk: Int) -> Int {
            var result = stscEntries[0].samplesPerChunk
            for e in stscEntries where e.firstChunk <= chunk {
                result = e.samplesPerChunk
            }
            return result
        }

        /// 定位第 index 个 sample（0-based）的字节偏移与大小
        func sampleLocation(_ target: Int) -> (offset: Int64, size: Int)? {
            guard target >= 0, target < sampleCount else { return nil }
            var sample = 0
            var chunk = 1 // 1-based
            while sample < sampleCount {
                let spc = samplesPerChunk(forChunk: chunk)
                guard chunk - 1 < chunkOffsets.count else { return nil }
                let chunkOffset = chunkOffsets[chunk - 1]
                var byteInChunk = 0
                for _ in 0..<spc {
                    guard sample < sampleCount else { break }
                    let s = size(of: sample)
                    if sample == target {
                        return (chunkOffset + Int64(byteInChunk), s)
                    }
                    byteInChunk += s
                    sample += 1
                }
                chunk += 1
            }
            return nil
        }
    }

    private static func findVideoTrak(moovBytes: [UInt8]) -> MP4Box? {
        // moovBytes 为 moov payload，顶层直接遍历 trak
        var offset = 0
        let end = moovBytes.count
        while offset + 8 <= end {
            guard let h = boxHeader(moovBytes, offset, end) else { return nil }
            if h.type == "trak" {
                let trak = MP4Box(type: h.type, payloadStart: Int64(h.payloadStart), boxEnd: Int64(h.boxEnd))
                if let hdlr = findBox("hdlr", in: moovBytes, base: h.payloadStart, limit: h.boxEnd),
                   isVideoHdlr(hdlr, moovBytes: moovBytes) {
                    return trak
                }
            }
            offset = h.boxEnd
        }
        return nil
    }

    private static func isVideoHdlr(_ hdlr: MP4Box, moovBytes: [UInt8]) -> Bool {
        // hdlr payload: version/flags(4) + pre_defined(4) + handler_type(4) = 相对 payloadStart 偏移 8
        let p = Int(hdlr.payloadStart) + 8
        guard p + 4 <= moovBytes.count else { return false }
        return Data(moovBytes[p..<p + 4]).fourCC(0) == "vide"
    }

    /// 解析 box 头（返回 header 后 payload 偏移、box 结束偏移、type），基于内存字节数组
    private static func boxHeader(_ bytes: [UInt8], _ offset: Int, _ end: Int) -> (type: String, payloadStart: Int, boxEnd: Int)? {
        guard offset + 8 <= end else { return nil }
        let size32 = Int(Data(bytes[offset..<offset + 4]).uint32BE(0))
        let t = Data(bytes[offset + 4..<offset + 8]).fourCC(0)
        var headerSize = 8
        var boxSize = size32
        if size32 == 1 {
            guard offset + 16 <= end else { return nil }
            boxSize = Int(Data(bytes[offset + 8..<offset + 16]).uint64BE(0))
            headerSize = 16
        } else if size32 == 0 {
            boxSize = end - offset
        }
        guard boxSize >= headerSize, offset + boxSize <= end else { return nil }
        return (t, offset + headerSize, offset + boxSize)
    }

    /// 递归查找 box（容器类型递归进入），用于定位嵌套较深的 covr / avcC 等
    private static func findBox(_ type: String, in bytes: [UInt8], base: Int, limit: Int? = nil) -> MP4Box? {
        let end = limit ?? bytes.count
        var offset = base
        while offset + 8 <= end {
            guard let h = boxHeader(bytes, offset, end) else { return nil }
            if h.type == type {
                return MP4Box(type: h.type, payloadStart: Int64(h.payloadStart), boxEnd: Int64(h.boxEnd))
            }
            let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl", "udta", "meta", "ilst", "stsd", "dinf", "edts", "mvex", "wave"]
            if containers.contains(h.type) {
                if let found = findBox(type, in: bytes, base: h.payloadStart, limit: h.boxEnd) {
                    return found
                }
            }
            offset = h.boxEnd
        }
        return nil
    }

    private struct CodecConfig {
        enum Kind { case h264(sps: [UInt8], pps: [UInt8]); case hevc(vps: [UInt8], sps: [UInt8], pps: [UInt8]) }
        let kind: Kind
    }

    private static func parseCodecConfig(_ stsd: MP4Box, moovBytes: [UInt8]) throws -> CodecConfig {
        // stsd payload: version/flags(4) + entry_count(4) + sample_entry
        let p = Int(stsd.payloadStart)
        guard p + 8 <= moovBytes.count else { throw NSError(domain: "MP4Cover", code: 3) }
        let entryStart = p + 8
        guard entryStart + 8 <= moovBytes.count else { throw NSError(domain: "MP4Cover", code: 4) }
        let entrySize = Int(Data(moovBytes[entryStart..<entryStart + 4]).uint32BE(0))
        guard entrySize >= 8, entryStart + entrySize <= moovBytes.count else {
            throw NSError(domain: "MP4Cover", code: 5)
        }
        // sample entry 非标准 box 容器（前段为固定字段），在其范围内线性扫描 avcC/hevC
        let entryRange = entryStart..<(entryStart + entrySize)
        if let avcC = scanBox("avcC", bytes: moovBytes, range: entryRange) {
            return try parseAVCC(avcC, moovBytes: moovBytes)
        }
        if let hevC = scanBox("hevC", bytes: moovBytes, range: entryRange) {
            return try parseHEVC(hevC, moovBytes: moovBytes)
        }
        throw NSError(domain: "MP4Cover", code: 6, userInfo: [NSLocalizedDescriptionKey: "unsupported codec"])
    }

    /// 在字节范围内扫描 fourCC 标识（box header 为 size+type，type 命中后回读 size 构造 box）
    private static func scanBox(_ type: String, bytes: [UInt8], range: Range<Int>) -> MP4Box? {
        let target = Array(type.utf8)
        guard range.lowerBound + 8 <= range.upperBound, target.count == 4 else { return nil }
        var i = range.lowerBound + 4   // 从 size 之后的 type 位置开始扫描
        while i + 4 <= range.upperBound {
            if bytes[i] == target[0], bytes[i + 1] == target[1], bytes[i + 2] == target[2], bytes[i + 3] == target[3] {
                let sizePos = i - 4
                let size32 = Int(Data(bytes[sizePos..<sizePos + 4]).uint32BE(0))
                if size32 >= 8, sizePos + size32 <= range.upperBound {
                    return MP4Box(type: type, payloadStart: Int64(i + 4), boxEnd: Int64(sizePos + size32))
                }
            }
            i += 1
        }
        return nil
    }

    private static func parseAVCC(_ avcC: MP4Box, moovBytes: [UInt8]) throws -> CodecConfig {
        let bytes = moovBytes
        var p = Int(avcC.payloadStart)
        guard p + 7 <= bytes.count else { throw NSError(domain: "MP4Cover", code: 6) }
        p += 5 // version/profile/compat/level/lenSize
        let numSPS = Int(bytes[p] & 0x1F); p += 1
        var sps: [UInt8] = []
        for _ in 0..<numSPS {
            guard p + 2 <= bytes.count else { break }
            let len = Int(Data(bytes[p..<p + 2]).uint16BE(0)); p += 2
            guard p + len <= bytes.count else { break }
            sps = Array(bytes[p..<p + len]); p += len
        }
        guard p + 1 <= bytes.count else { throw NSError(domain: "MP4Cover", code: 7) }
        let numPPS = Int(bytes[p]); p += 1
        var pps: [UInt8] = []
        for _ in 0..<numPPS {
            guard p + 2 <= bytes.count else { break }
            let len = Int(Data(bytes[p..<p + 2]).uint16BE(0)); p += 2
            guard p + len <= bytes.count else { break }
            pps = Array(bytes[p..<p + len]); p += len
        }
        guard !sps.isEmpty, !pps.isEmpty else { throw NSError(domain: "MP4Cover", code: 8) }
        return CodecConfig(kind: .h264(sps: sps, pps: pps))
    }

    private static func parseHEVC(_ hevC: MP4Box, moovBytes: [UInt8]) throws -> CodecConfig {
        let bytes = moovBytes
        var p = Int(hevC.payloadStart)
        guard p + 23 <= bytes.count else { throw NSError(domain: "MP4Cover", code: 9) }
        p += 22 // version/profile/level/… 跳过，定位到 numOfArrays
        let numArrays = Int(bytes[p]); p += 1
        var vps: [UInt8] = []
        var sps: [UInt8] = []
        var pps: [UInt8] = []
        for _ in 0..<numArrays {
            guard p + 3 <= bytes.count else { break }
            let nalType = bytes[p] & 0x3F
            let numNalus = Int(Data(bytes[p + 1..<p + 3]).uint16BE(0)); p += 3
            for _ in 0..<numNalus {
                guard p + 2 <= bytes.count else { break }
                let len = Int(Data(bytes[p..<p + 2]).uint16BE(0)); p += 2
                guard p + len <= bytes.count else { break }
                let nalu = Array(bytes[p..<p + len]); p += len
                if nalType == 32 { vps = nalu }
                else if nalType == 33 { sps = nalu }
                else if nalType == 34 { pps = nalu }
            }
        }
        guard !vps.isEmpty, !sps.isEmpty, !pps.isEmpty else { throw NSError(domain: "MP4Cover", code: 10) }
        return CodecConfig(kind: .hevc(vps: vps, sps: sps, pps: pps))
    }

    // MARK: VideoToolbox 单帧解码

    private static func decodeFrame(codec: CodecConfig, frameData: Data) async -> UIImage? {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: decodeFrameSync(codec: codec, frameData: frameData))
            }
        }
    }

    private static func decodeFrameSync(codec: CodecConfig, frameData: Data) -> UIImage? {
        let formatDesc: CMVideoFormatDescription?
        switch codec.kind {
        case .h264(let sps, let pps):
            formatDesc = makeH264FormatDesc(sps: sps, pps: pps)
        case .hevc(let vps, let sps, let pps):
            formatDesc = makeHEVCFormatDesc(vps: vps, sps: sps, pps: pps)
        }
        guard let formatDesc else { return nil }

        final class Ref { var image: CGImage? }
        let ref = Ref()
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { (refCon, _, status, _, imageBuffer, _, _) in
                guard status == noErr, let imageBuffer, let refCon else { return }
                let box = Unmanaged<Ref>.fromOpaque(refCon).takeUnretainedValue()
                let ci = CIImage(cvPixelBuffer: imageBuffer)
                box.image = CIContext().createCGImage(ci, from: ci.extent)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(ref).toOpaque()
        )

        let pixelAttrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        var session: VTDecompressionSession?
        let createStatus = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDesc,
            decoderSpecification: nil,
            imageBufferAttributes: pixelAttrs as CFDictionary,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )
        guard createStatus == noErr, let session else { return nil }

        guard let sampleBuffer = makeSampleBuffer(formatDesc: formatDesc, data: frameData) else { return nil }

        var flagsOut = VTDecodeInfoFlags()
        let decStatus = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sampleBuffer,
            flags: [._EnableAsynchronousDecompression],
            frameRefcon: nil, infoFlagsOut: &flagsOut
        )
        guard decStatus == noErr else { return nil }
        VTDecompressionSessionWaitForAsynchronousFrames(session)

        guard let cg = ref.image else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func makeSampleBuffer(formatDesc: CMVideoFormatDescription, data: Data) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: data.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard bbStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        let replaceStatus = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
            guard let base = ptr.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: data.count
            )
        }
        guard replaceStatus == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        let sbStatus = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDesc,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard sbStatus == noErr else { return nil }
        return sampleBuffer
    }

    private static func makeH264FormatDesc(sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        let spsData = Data(sps), ppsData = Data(pps)
        var spsPtr: UnsafePointer<UInt8>?, ppsPtr: UnsafePointer<UInt8>?
        spsData.withUnsafeBytes { spsPtr = $0.bindMemory(to: UInt8.self).baseAddress }
        ppsData.withUnsafeBytes { ppsPtr = $0.bindMemory(to: UInt8.self).baseAddress }
        guard let spsPtr, let ppsPtr else { return nil }
        var paramPtrs: [UnsafePointer<UInt8>] = [spsPtr, ppsPtr]
        var paramSizes: [Int] = [sps.count, pps.count]
        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: 2,
            parameterSetPointers: &paramPtrs,
            parameterSetSizes: &paramSizes,
            nalUnitHeaderLength: 4,
            formatDescriptionOut: &desc
        )
        return status == noErr ? desc : nil
    }

    private static func makeHEVCFormatDesc(vps: [UInt8], sps: [UInt8], pps: [UInt8]) -> CMVideoFormatDescription? {
        let vpsData = Data(vps), spsData = Data(sps), ppsData = Data(pps)
        var vpsPtr: UnsafePointer<UInt8>?, spsPtr: UnsafePointer<UInt8>?, ppsPtr: UnsafePointer<UInt8>?
        vpsData.withUnsafeBytes { vpsPtr = $0.bindMemory(to: UInt8.self).baseAddress }
        spsData.withUnsafeBytes { spsPtr = $0.bindMemory(to: UInt8.self).baseAddress }
        ppsData.withUnsafeBytes { ppsPtr = $0.bindMemory(to: UInt8.self).baseAddress }
        guard let vpsPtr, let spsPtr, let ppsPtr else { return nil }
        var paramPtrs: [UnsafePointer<UInt8>] = [vpsPtr, spsPtr, ppsPtr]
        var paramSizes: [Int] = [vps.count, sps.count, pps.count]
        var desc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
            allocator: kCFAllocatorDefault,
            parameterSetCount: 3,
            parameterSetPointers: &paramPtrs,
            parameterSetSizes: &paramSizes,
            nalUnitHeaderLength: 4,
            extensions: nil,
            formatDescriptionOut: &desc
        )
        return status == noErr ? desc : nil
    }
}
