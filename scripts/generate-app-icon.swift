#!/usr/bin/env swift
import Foundation

// Use the same artwork renderer for the primary icon and its Classic preview.
// This keeps regeneration from restoring an older, mismatched icon.
let generator = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appending(path: "generate-alternate-app-icons.swift")
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
process.arguments = ["swift", generator.path, "--primary-only"]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
