import Foundation
import CoreVideo

struct GrayImage {
    let pixels: [UInt8]
    let width: Int
    let height: Int

    func pixel(_ x: Int, _ y: Int) -> Int { Int(pixels[y * width + x]) }
}

struct MsiDecodeResult {
    let digits7: String
    let fullDigits: String
    let method: String
}

private struct BitRow {
    let bits: [Bool]
    var size: Int { bits.count }
    subscript(i: Int) -> Bool { bits[i] }
    func getNextSet(_ from: Int) -> Int {
        for i in from..<bits.count { if bits[i] { return i } }
        return bits.count
    }
    func isRange(_ start: Int, _ end: Int, value: Bool) -> Bool {
        if start >= end { return true }
        for i in start..<end { if bits[i] != value { return false } }
        return true
    }
}

enum MsiPlesseyDecoder {

    private static let bitsToDigit: [[Int]: Int] = [
        [0, 0, 0, 0]: 0, [0, 0, 0, 1]: 1,
        [0, 0, 1, 0]: 2, [0, 0, 1, 1]: 3,
        [0, 1, 0, 0]: 4, [0, 1, 0, 1]: 5,
        [0, 1, 1, 0]: 6, [0, 1, 1, 1]: 7,
        [1, 0, 0, 0]: 8, [1, 0, 0, 1]: 9,
    ]

    // ── ZXing CHARACTER_ENCODINGS (Approach B) ──────────────────────────────────

    private static let zxingCharacterEncodings: [Int] = [
        0x924, 0x926, 0x934, 0x936, 0x9A4, 0x9A6, 0x9B4, 0x9B6, 0xD24, 0xD26
    ]
    private static let zxingAlphabet = "0123456789"
    private static let zxingStart = 0x06
    private static let zxingEnd = 0x09

    // ── Cross-frame confidence ──────────────────────────────────────────────────

    private static let scoreCombined = 3
    private static let scoreRowScan = 2
    private static let scoreZxingRowScan = 2
    private static let scoreColGreedy = 1
    private static let confidenceThreshold = 5

    private static let frameLock = NSLock()
    private static var frameScores: [String: Int] = [:]

    static func reset() {
        frameLock.withLock { frameScores.removeAll() }
    }

    // ── Public API ──────────────────────────────────────────────────────────────

    static func decode(from pixelBuffer: CVPixelBuffer) -> MsiDecodeResult? {
        guard let gray = extractGrayscale(from: pixelBuffer) else { return nil }
        return decodeGray(gray)
    }

    static func decodeGray(_ gray: GrayImage) -> MsiDecodeResult? {
        let crop = isolateBarcode(gray) ?? gray
        guard let single = decodeBarcodeV2(crop) else { return nil }

        let points: Int
        switch single.method {
        case "combined": points = scoreCombined
        case "row_scan": points = scoreRowScan
        case "zxing_row_scan": points = scoreZxingRowScan
        default: points = scoreColGreedy
        }

        let total = frameLock.withLock { () -> Int in
            let t = (frameScores[single.digits7] ?? 0) + points
            frameScores[single.digits7] = t
            return t
        }

        if total >= confidenceThreshold {
            frameLock.withLock { frameScores.removeAll() }
            return single
        }
        return nil
    }

    // ── Rotation ────────────────────────────────────────────────────────────────

    static func rotateCW90(_ src: GrayImage) -> GrayImage {
        let dstW = src.height; let dstH = src.width
        var dst = [UInt8](repeating: 0, count: dstW * dstH)
        for y in 0..<src.height {
            for x in 0..<src.width {
                dst[x * dstW + (dstW - 1 - y)] = src.pixels[y * src.width + x]
            }
        }
        return GrayImage(pixels: dst, width: dstW, height: dstH)
    }

    static func rotateCW180(_ src: GrayImage) -> GrayImage {
        let w = src.width; let h = src.height
        var dst = [UInt8](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            dst[i] = src.pixels[w * h - 1 - i]
        }
        return GrayImage(pixels: dst, width: w, height: h)
    }

    static func rotateCW270(_ src: GrayImage) -> GrayImage {
        let dstW = src.height; let dstH = src.width
        var dst = [UInt8](repeating: 0, count: dstW * dstH)
        for y in 0..<src.height {
            for x in 0..<src.width {
                dst[(dstH - 1 - x) * dstW + y] = src.pixels[y * src.width + x]
            }
        }
        return GrayImage(pixels: dst, width: dstW, height: dstH)
    }

    // ── CVPixelBuffer → GrayImage (cropped to center) ──────────────────────────

    static func extractGrayscale(from pixelBuffer: CVPixelBuffer, centerFraction: Double = 0.6) -> GrayImage? {
        extractGrayscale(from: pixelBuffer, widthFraction: centerFraction, heightFraction: centerFraction)
    }

    static func extractGrayscale(from pixelBuffer: CVPixelBuffer, widthFraction: Double, heightFraction: Double) -> GrayImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        let fullWidth = CVPixelBufferGetWidth(pixelBuffer)
        let fullHeight = CVPixelBufferGetHeight(pixelBuffer)

        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return nil
        }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let ptr = baseAddress.assumingMemoryBound(to: UInt8.self)

        let cropW = Int(Double(fullWidth) * widthFraction)
        let cropH = Int(Double(fullHeight) * heightFraction)
        let left = (fullWidth - cropW) / 2
        let top = (fullHeight - cropH) / 2

        var pixels = [UInt8](repeating: 0, count: cropW * cropH)
        for y in 0..<cropH {
            let src = ptr + (top + y) * bytesPerRow + left
            let dst = y * cropW
            for x in 0..<cropW {
                pixels[dst + x] = src[x]
            }
        }
        return GrayImage(pixels: pixels, width: cropW, height: cropH)
    }

    // ── Barcode band isolation ──────────────────────────────────────────────────

    private static func isolateBarcode(_ img: GrayImage) -> GrayImage? {
        let w = img.width; let h = img.height
        let scores = (0..<h).map { rowTransitions(img, $0) }
        guard let maxScore = scores.max(), maxScore >= 10 else { return nil }
        let threshold = maxScore / 3

        var bestStart = 0; var bestEnd = 0; var bestSum = 0
        var bandStart = -1; var bandSum = 0

        for y in 0..<h {
            if scores[y] > threshold {
                if bandStart < 0 { bandStart = y }
                bandSum += scores[y]
            } else {
                if bandStart >= 0, y - bandStart >= 5, bandSum > bestSum {
                    bestSum = bandSum; bestStart = bandStart; bestEnd = y
                }
                bandStart = -1; bandSum = 0
            }
        }
        if bandStart >= 0, h - bandStart >= 5, bandSum > bestSum {
            bestStart = bandStart; bestEnd = h
        }
        if bestEnd - bestStart < 5 { return nil }

        let top = max(bestStart - 4, 0)
        let bottom = min(bestEnd + 4, h)
        let cropH = bottom - top
        var out = [UInt8](repeating: 0, count: w * cropH)
        for i in 0..<(w * cropH) {
            out[i] = img.pixels[top * w + (i % w) + (i / w) * w]
        }
        return GrayImage(pixels: out, width: w, height: cropH)
    }

    private static func rowTransitions(_ img: GrayImage, _ y: Int) -> Int {
        let w = img.width
        var mn = Int.max, mx = 0
        for x in 0..<w {
            let p = img.pixel(x, y)
            if p < mn { mn = p }; if p > mx { mx = p }
        }
        if mx - mn < 30 { return 0 }
        let thr = (mn + mx) / 2
        var prev = img.pixel(0, y) < thr ? 1 : 0
        var count = 0
        for x in 1..<w {
            let cur = img.pixel(x, y) < thr ? 1 : 0
            if cur != prev { count += 1; prev = cur }
        }
        return count
    }

    // ── V2 decodeBarcode (dual approach + reconcile) ────────────────────────────

    private static func decodeBarcodeV2(_ img: GrayImage) -> MsiDecodeResult? {
        var bimodal: String?
        var zxing: String?
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            if i == 0 {
                bimodal = rowScan(img).flatMap { luhnNormalize($0) }
            } else {
                zxing = zxingRowScan(img).flatMap { luhnNormalize($0) }
            }
        }
        if let b = bimodal, let z = zxing, b.prefix(7) == z.prefix(7) {
            return MsiDecodeResult(digits7: String(b.prefix(7)), fullDigits: b, method: "combined")
        }
        if let b = bimodal {
            return MsiDecodeResult(digits7: String(b.prefix(7)), fullDigits: b, method: "row_scan")
        }
        if let z = zxing {
            return MsiDecodeResult(digits7: String(z.prefix(7)), fullDigits: z, method: "zxing_row_scan")
        }
        if let v = colGreedy(img) {
            return MsiDecodeResult(digits7: String(v.prefix(7)), fullDigits: v, method: "col_greedy")
        }
        return nil
    }

    // ── Approach A: Bimodal row scan ────────────────────────────────────────────

    private static func rle(_ row: [Int]) -> [(isDark: Bool, length: Int)] {
        guard !row.isEmpty else { return [] }
        var runs: [(Bool, Int)] = []
        var isDark = row[0] != 0
        var count = 1
        for i in 1..<row.count {
            let d = row[i] != 0
            if d == isDark { count += 1 }
            else { runs.append((isDark, count)); isDark = d; count = 1 }
        }
        runs.append((isDark, count))
        return runs
    }

    private static func binariseRow(_ img: GrayImage, _ y: Int, _ thr: Int) -> [Int] {
        (0..<img.width).map { img.pixel($0, y) < thr ? 1 : 0 }
    }

    private static func bimodalSplit(_ darkWidths: [Int]) -> Double? {
        guard darkWidths.count >= 6 else { return nil }
        let trimmed = darkWidths.sorted().dropLast(2)
        let vals = Array(Set(trimmed)).sorted()
        guard vals.count >= 2 else { return nil }
        var bestGap = 0; var bestSplit = 0.0
        for i in 0..<(vals.count - 1) {
            let gap = vals[i + 1] - vals[i]
            if gap > bestGap { bestGap = gap; bestSplit = Double(vals[i] + vals[i + 1]) / 2.0 }
        }
        return bestGap >= 1 ? bestSplit : nil
    }

    private static func decodeRuns(_ runs: [(Bool, Int)], _ split: Double) -> String? {
        var pos = -1
        for i in runs.indices {
            if runs[i].0 && Double(runs[i].1) > split { pos = i + 2; break }
        }
        guard pos >= 0 else { return nil }

        var result = ""
        while pos + 6 < runs.count {
            let bits = (0..<4).map { j -> Int in Double(runs[pos + j * 2].1) > split ? 1 : 0 }
            guard let digit = bitsToDigit[bits] else { break }
            result.append(String(digit))
            pos += 8
        }
        return result.count >= 7 ? result : nil
    }

    private static func rowScan(_ img: GrayImage) -> String? {
        var validVotes: [String: Int] = [:]
        var rawVotes: [String: Int] = [:]
        var bestVotes = 0, bestRaw = 0

        for y in 0..<img.height {
            var mn = Int.max, mx = 0
            for x in 0..<img.width {
                let p = img.pixel(x, y)
                if p < mn { mn = p }; if p > mx { mx = p }
            }
            guard mx - mn >= 30 else { continue }

            for thrPct in stride(from: 20, through: 80, by: 5) {
                let thr = mn + (mx - mn) * thrPct / 100
                let bin = binariseRow(img, y, thr)
                let runs = rle(bin)
                guard runs.count >= 55 && runs.count <= 110 else { continue }
                let darkWidths = runs.filter { $0.0 }.map { $0.1 }
                guard let split = bimodalSplit(darkWidths) else { continue }
                guard let value = decodeRuns(runs, split), value.count >= 7 else { continue }
                guard !value.allSatisfy({ $0 == value.first }) else { continue }

                if let normed = luhnNormalize(value) {
                    let c = (validVotes[normed] ?? 0) + 1
                    validVotes[normed] = c
                    if c > bestVotes { bestVotes = c }
                } else {
                    let c = (rawVotes[value] ?? 0) + 1
                    rawVotes[value] = c
                    if c > bestRaw { bestRaw = c }
                }
            }
            if bestVotes >= 2 || bestRaw >= 2 { break }
        }

        if bestVotes >= 2 {
            return validVotes.first(where: { $0.value == bestVotes })!.key
        }
        if bestRaw >= 2 {
            return rawVotes.first(where: { $0.value == bestRaw })!.key
        }
        return nil
    }

    // ── Approach B: ZXing run-counter row scan ──────────────────────────────────

    private static func zxingRowScan(_ img: GrayImage) -> String? {
        var validVotes: [String: Int] = [:]
        var rawVotes: [String: Int] = [:]
        var bestVotes = 0, bestRaw = 0

        for y in 0..<img.height {
            var mn = Int.max, mx = 0
            for x in 0..<img.width {
                let p = img.pixel(x, y)
                if p < mn { mn = p }; if p > mx { mx = p }
            }
            guard mx - mn >= 30 else { continue }

            for thrPct in stride(from: 20, through: 80, by: 5) {
                let thr = mn + (mx - mn) * thrPct / 100
                let bitRow = BitRow(bits: (0..<img.width).map { img.pixel($0, y) < thr })
                guard let decoded = zxingDecodeRow(bitRow) else { continue }
                guard !decoded.allSatisfy({ $0 == decoded.first }) else { continue }

                if let normed = luhnNormalize(decoded) {
                    let c = (validVotes[normed] ?? 0) + 1
                    validVotes[normed] = c
                    if c > bestVotes { bestVotes = c }
                } else {
                    let c = (rawVotes[decoded] ?? 0) + 1
                    rawVotes[decoded] = c
                    if c > bestRaw { bestRaw = c }
                }
            }
            if bestVotes >= 2 || bestRaw >= 2 { break }
        }

        if bestVotes >= 2 {
            return validVotes.first(where: { $0.value == bestVotes })!.key
        }
        if bestRaw >= 2 {
            return rawVotes.first(where: { $0.value == bestRaw })!.key
        }
        return nil
    }

    private static func zxingDecodeRow(_ row: BitRow) -> String? {
        var counters = [Int](repeating: 0, count: 8)
        guard let start = zxingFindStart(row, &counters) else { return nil }
        let avgWidth = start[2]
        var nextStart = row.getNextSet(start[1])
        var result = ""

        while true {
            guard zxingRecordPattern(row, nextStart, &counters, 8) else {
                guard zxingFindEnd(row, nextStart, &counters, avgWidth) != nil else { return nil }
                break
            }
            let pattern = zxingToPattern(counters, 8, avgWidth)
            guard let ch = zxingPatternToChar(pattern) else {
                guard zxingFindEnd(row, nextStart, &counters, avgWidth) != nil else { return nil }
                break
            }
            result.append(ch)
            for c in counters { nextStart += c }
            nextStart = row.getNextSet(nextStart)
        }

        return result.count >= 3 ? result : nil
    }

    private static func zxingFindStart(_ row: BitRow, _ counters: inout [Int]) -> [Int]? {
        let width = row.size
        let rowOffset = row.getNextSet(0)
        var cp = 0
        var ps = rowOffset
        var isWhite = false

        counters[0] = 0; counters[1] = 0

        for i in rowOffset..<width {
            if row[i] != isWhite {
                counters[cp] += 1
            } else {
                if cp == 1 {
                    if counters[1] != 0 {
                        let factor = Float(counters[0]) / Float(counters[1])
                        if factor >= 1.5 && factor <= 5.0 {
                            let avgWidth = zxingCalcAvgWidth(counters, 2)
                            if zxingToPattern(counters, 2, avgWidth) == zxingStart {
                                let quietStart = max(0, ps - ((i - ps) >> 1))
                                if row.isRange(quietStart, ps, value: false) {
                                    return [ps, i, avgWidth]
                                }
                            }
                        }
                    }
                    ps += counters[0] + counters[1]
                    counters[0] = 0; counters[1] = 0
                    cp -= 1
                } else {
                    cp += 1
                }
                counters[cp] = 1
                isWhite = !isWhite
            }
        }
        return nil
    }

    private static func zxingFindEnd(_ row: BitRow, _ rowOffset: Int, _ counters: inout [Int], _ avgWidth: Int) -> [Int]? {
        let width = row.size
        var cp = 0
        var ps = rowOffset
        var isWhite = false

        counters[0] = 0; counters[1] = 0; counters[2] = 0

        for i in rowOffset..<width {
            if row[i] != isWhite {
                counters[cp] += 1
            } else {
                if cp == 2 {
                    if counters[0] != 0 {
                        let factor = Float(counters[1]) / Float(counters[0])
                        if factor >= 1.5 && factor <= 5.0 && zxingToPattern(counters, 3, avgWidth) == zxingEnd {
                            let minEnd = min(row.size - 1, i + ((i - ps) >> 1))
                            if row.isRange(i, minEnd, value: false) {
                                return [ps, i]
                            }
                        }
                    }
                    return nil
                }
                cp += 1
                counters[cp] = 1
                isWhite = !isWhite
            }
        }
        return nil
    }

    private static func zxingRecordPattern(_ row: BitRow, _ start: Int, _ counters: inout [Int], _ n: Int) -> Bool {
        for i in 0..<n { counters[i] = 0 }
        if start >= row.size { return false }
        var isWhite = !row[start]
        var cp = 0; var i = start
        while i < row.size {
            if row[i] != isWhite { counters[cp] += 1 }
            else {
                cp += 1
                if cp == n { break }
                counters[cp] = 1
                isWhite = !isWhite
            }
            i += 1
        }
        return cp == n || (cp == n - 1 && i == row.size)
    }

    private static func zxingCalcAvgWidth(_ counters: [Int], _ len: Int) -> Int {
        var mn = Int.max; var mx = 0
        for i in 0..<len {
            if counters[i] < mn { mn = counters[i] }
            if counters[i] > mx { mx = counters[i] }
        }
        return ((mx << 8) + (mn << 8)) / 2
    }

    private static func zxingToPattern(_ counters: [Int], _ len: Int, _ avgWidth: Int) -> Int {
        var pattern = 0; var bit = 1; var doubleBit = 3
        for i in 0..<len {
            if (counters[i] << 8) < avgWidth {
                pattern = (pattern << 1) | bit
            } else {
                pattern = (pattern << 2) | doubleBit
            }
            bit ^= 1
            doubleBit ^= 3
        }
        return pattern
    }

    private static func zxingPatternToChar(_ pattern: Int) -> Character? {
        for (i, enc) in zxingCharacterEncodings.enumerated() {
            if enc == pattern { return zxingAlphabet[zxingAlphabet.index(zxingAlphabet.startIndex, offsetBy: i)] }
        }
        return nil
    }

    // ── Fallback: Column greedy ─────────────────────────────────────────────────

    private static func colSignal(_ img: GrayImage) -> [Double]? {
        let w = img.width; let h = img.height
        let pctIdx = max(Int(Double(h) * 0.10), 0)
        var sig = [Double](repeating: 0, count: w)
        for x in 0..<w {
            var col = (0..<h).map { Double(img.pixel(x, $0)) }
            col.sort()
            sig[x] = col[pctIdx]
        }
        guard let mn = sig.min(), let mx = sig.max(), mx - mn >= 10.0 else { return nil }
        return sig.map { 1.0 - ($0 - mn) / (mx - mn) }
    }

    private static func greedy(_ sig: [Double], _ N: Double, _ W: Double, _ offset: Int) -> String? {
        let nPx = Int(N.rounded()); let wPx = Int(W.rounded()); let pw = nPx + wPx
        var x = offset + wPx + nPx
        var result = ""
        while x + pw * 4 <= sig.count && result.count < 12 {
            let bits = (0..<4).map { j -> Int in
                let s = x + j * pw; let e = min(s + pw, sig.count)
                let sum = (s..<e).reduce(0.0) { $0 + sig[$1] }
                return sum / Double(e - s) > 0.5 ? 1 : 0
            }
            guard let digit = bitsToDigit[bits] else { break }
            result.append(String(digit))
            x += pw * 4
        }
        return result.count >= 7 ? result : nil
    }

    private static func colGreedy(_ img: GrayImage) -> String? {
        guard let sig = colSignal(img) else { return nil }
        let w = sig.count
        var votes: [String: Int] = [:]

        var N = 1.5
        while N <= 5.0 {
            for ratioStep in 0...2 {
                let W = N * (2.0 + Double(ratioStep) * 0.5)
                let nPx = Int(N.rounded()); let wPx = Int(W.rounded()); let pw = nPx + wPx
                let minW = wPx + nPx + 7 * 4 * pw + nPx + wPx + nPx
                guard minW <= w else { continue }
                let maxOff = min(w - minW, 80)
                for off in stride(from: 0, through: maxOff, by: 5) {
                    guard let r = greedy(sig, N, W, off) else { continue }
                    guard !r.allSatisfy({ $0 == r.first }) else { continue }
                    if let normed = luhnNormalize(r) {
                        votes[normed, default: 0] += 1
                    }
                }
            }
            N += 0.5
        }
        guard let best = votes.max(by: { $0.value < $1.value }), best.value >= 5 else { return nil }
        return best.key
    }

    // ── Luhn check digit ────────────────────────────────────────────────────────

    private static func luhnCheck(_ digits: String) -> Character {
        var total = 0
        for (i, ch) in digits.reversed().enumerated() {
            var d = ch.wholeNumberValue ?? 0
            if i % 2 == 0 { d *= 2; if d > 9 { d -= 9 } }
            total += d
        }
        let check = (10 - total % 10) % 10
        return Character(String(check))
    }

    private static func luhnNormalize(_ s: String) -> String? {
        guard s.contains(where: { $0 != "0" }) else { return nil }
        let len = min(s.count, 10)
        for n in stride(from: len, through: 8, by: -1) {
            let prefix = String(s.prefix(n))
            let dataPart = String(prefix.prefix(n - 1))
            if luhnCheck(dataPart) == prefix.last {
                guard prefix.contains(where: { $0 != "0" }) else { continue }
                return prefix
            }
        }
        return nil
    }
}
