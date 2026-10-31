#!/usr/bin/env swift
// Synthesises the keyboard's fallback key click: the sound used when iOS's own key_press_click.caf cannot be read.
// Original synthesis, nothing taken from Apple's audio files. About 30 ms, mono, 44.1 kHz, 16-bit, peak about 0.38.
//
// Usage: swift scripts/make-key-click.swift iOS/RemoteKeyboardExtension/Resources/key-click.caf
//
// Recipe: a 2 ms burst of seeded noise (the contact), a 2.3 kHz damped sine (the keycap, decay 4 ms) and a 420 Hz damped
// sine (the body, decay 7 ms). The seed is fixed, so the same command always writes the same file.
import AVFoundation
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-key-click.swift <output.caf>\n".utf8))
    exit(2)
}

let sampleRate = 44_100.0
let frames = Int(sampleRate * 0.030)
var seed: UInt64 = 0x5EED_C11C
func noise() -> Double {
    seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    return Double(Int64(bitPattern: seed >> 11) % 2_000_001) / 1_000_000.0 - 1.0
}

var samples = [Double](repeating: 0, count: frames)
for i in 0..<frames {
    let t = Double(i) / sampleRate
    let burst = t < 0.002 ? noise() * (1 - t / 0.002) : 0
    let cap = sin(2 * .pi * 2300 * t) * exp(-t / 0.004)
    let body = sin(2 * .pi * 420 * t) * exp(-t / 0.007) * 0.6
    // A 0.3 ms ramp-in keeps the first sample at zero, so the file does not start with a pop.
    let attack = min(1, t / 0.0003)
    samples[i] = (0.5 * burst + 0.8 * cap + body) * attack
}
let peak = samples.map { abs($0) }.max() ?? 1
let scale = 0.38 / peak
for i in samples.indices {
    // The last 3 ms fade to zero.
    let tail = min(1, Double(frames - i) / (sampleRate * 0.003))
    samples[i] *= scale * tail
}

let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
buffer.frameLength = AVAudioFrameCount(frames)
for i in 0..<frames { buffer.int16ChannelData![0][i] = Int16((samples[i] * 32767).rounded()) }

let url = URL(fileURLWithPath: arguments[1])
let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatInt16, interleaved: true)
try file.write(from: buffer)
print("wrote \(frames) frames to \(url.path)")
