# BarcodeScanner with MSI Plessey Fallback

iOS barcode scanner built with SwiftUI and Apple Vision, featuring a custom MSI Plessey decoder as fallback for symbologies not natively supported by Vision.

## Features

- **Apple Vision** primary detection for standard 1D barcodes
- **MSI Plessey fallback** decoder when Vision does not recognize the barcode
- Center-crops camera frame to viewfinder area for reliable MSI decoding
- Device orientation-aware (portrait and landscape)
- Torch toggle for low-light scanning
- Rescan capability

## Supported Barcode Types

| Symbology | Detection |
|-----------|-----------|
| Code 128 | Vision |
| EAN-13 / UPC-A | Vision (UPC-A normalized to 12 digits) |
| EAN-8 | Vision |
| UPC-E | Vision |
| Interleaved 2 of 5 | Vision |
| GS1 DataBar | Vision |
| GS1 DataBar Expanded | Vision |
| GS1 DataBar Limited | Vision |
| MSI Plessey | Custom decoder (fallback) |

The MSI Plessey decoder triggers only after Vision fails on 5 consecutive frames, preventing premature fallback.

## Requirements

- iOS 15.0+
- Xcode 14+
- Physical device with camera (MSI Plessey decoding requires camera feed)

## Architecture

```
BarcodeScannerView.swift     — SwiftUI UI + ScanDelegate (Vision + MSI integration)
MsiPlesseyDecoder.swift      — MSI Plessey decode engine (Swift port of Android decoder)
ContentView.swift             — App entry point
```

### MSI Plessey Decoder

The fallback decoder (`MsiPlesseyDecoder`) performs:

1. **GrayImage extraction** — reads Y (luminance) plane from camera pixel buffer, cropped to center 60%
2. **Barcode band isolation** — finds the horizontal band with most transitions, isolates it
3. **Row scan** — scans each row with multiple binarization thresholds, validates via bimodal split of run-lengths, decodes MSI 4-bar-per-digit encoding, verified with Luhn check digit
4. **Column greedy fallback** — synthesizes a column-darker-than-row signal, tries multiple narrow/wide width ratios and offsets, votes on consistent results (requires ≥5 votes)

All results must pass Luhn check-digit validation; all-zero strings are rejected.

## Setup

1. Open `BarcodeScanner.xcodeproj` in Xcode
2. Select your development team in Signing & Capabilities
3. Build and run on a physical iOS device

## Credits

Based on the [ZXing_BarcodeReader](https://github.com/gjmoyer/ZXing_BarcodeReader) Android app. The MSI Plessey decoder is a Swift port of the Kotlin `MsiPlesseyBarcodeDecoder`.
