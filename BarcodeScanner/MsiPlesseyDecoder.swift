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

enum MsiPlesseyDecoder {

    private static let bitsToDigit: [[Int]: Int] = [
        [0, 0, 0, 0]: 0, [0, 0, 0, 1]: 1,
        [0, 0, 1, 0]: 2, [0, 0, 1, 1]: 3,
        [0, 1, 0, 0]: 4, [0, 1, 0, 1]: 5,
        [0, 1, 1, 0]: 6, [0, 1, 1, 1]: 7,
        [1, 0, 0, 0]: 8, [1, 0, 0, 1]: 9,
    ]

    // ── Public API ──────────────────────────────────────────────────────────────

    static func decode(from pixelBuffer: CVPixelBuffer) -> MsiDecodeResult? {
        guard let gray = extractGrayscale(from: pixelBuffer) else { return nil }
        return decodeGray(gray)
    }

    static func decodeGray(_ gray: GrayImage) -> MsiDecodeResult? {
        let crop = isolateBarcode(gray) ?? gray
        return decodeBarcode(crop)
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
        let mn = (0..<w).map { img.pixel($0, y) }.min() ?? 0
        let mx = (0..<w).map { img.pixel($0, y) }.max() ?? 0
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

    // ── MSI Plessey decode ──────────────────────────────────────────────────────

    private static func decodeBarcode(_ img: GrayImage) -> MsiDecodeResult? {
        if let v = rowScan(img), let norm = luhnNormalize(v) {
            return MsiDecodeResult(digits7: String(norm.prefix(7)), fullDigits: norm, method: "row_scan")
        }
        if let v = colGreedy(img) {
            return MsiDecodeResult(digits7: String(v.prefix(7)), fullDigits: v, method: "col_greedy")
        }
        return nil
    }

    // ── RLE ─────────────────────────────────────────────────────────────────────

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

    // ── Bimodal split ───────────────────────────────────────────────────────────

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

    // ── Run-list → digit string ─────────────────────────────────────────────────

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

    // ── Row scan ────────────────────────────────────────────────────────────────

    private static func rowScan(_ img: GrayImage) -> String? {
        var validVotes: [String: Int] = [:]
        var rawVotes: [String: Int] = [:]

        for y in 0..<img.height {
            let vals = (0..<img.width).map { img.pixel($0, y) }
            let mn = vals.min() ?? 0; let mx = vals.max() ?? 0
            guard mx - mn >= 30 else { continue }

            for thrPct in stride(from: 20, through: 80, by: 5) {
                let thr = mn + (mx - mn) * thrPct / 100
                let bin = binariseRow(img, y, thr)
                let runs = rle(bin)
                guard runs.count >= 55 && runs.count <= 110 else { continue }
                let darkWidths = runs.filter { $0.0 }.map { $0.1 }
                guard let split = bimodalSplit(darkWidths) else { continue }
                guard let value = decodeRuns(runs, split), value.count >= 7 else { continue }

                if let normed = luhnNormalize(value) {
                    validVotes[normed, default: 0] += 1
                } else {
                    rawVotes[value, default: 0] += 1
                }
            }
        }

        if let best = validVotes.max(by: { $0.value < $1.value }), best.value >= 2 {
            return best.key
        }
        if let best = rawVotes.max(by: { $0.value < $1.value }), best.value >= 2 {
            return best.key
        }
        return nil
    }

    // ── Column greedy ───────────────────────────────────────────────────────────

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
