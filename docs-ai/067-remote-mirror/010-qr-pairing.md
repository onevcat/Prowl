# 067.010 — QR device pairing

Status: Implemented (2026-10-01).

## Context and design

Manual mobile enrollment requires copying an IP, port and short-lived code. Add a
QR representation to Host's existing Add a Device sheet and an explicit scanner in
both mobile connection forms. Scanning fills a fresh connection and immediately
uses the existing authenticated enrollment flow; it never reuses a saved credential.

The versioned JSON payload contains type, version, numeric IP address, port, code
and expiry (Unix seconds). Clients validate bounded input, field types, IP, port,
code and expiry before connecting. Host remains authoritative for code expiry and
single use. Do not log or persist QR payloads. No URL registration or network
protocol change is required. Multiple Host interfaces require an address picker.

macOS uses Core Image to generate QR images. iOS uses the system VisionKit scanner
with camera permission and manual fallback. Android uses embedded ZXing so scanning
works without Google Play Services. Cancel/denied/unsupported camera retains manual
entry. Test shared parser vectors, malformed/expired payloads and QR decoding;
build all three targets. Physical camera acceptance is separate from simulator tests.

## Verification and remaining acceptance

macOS Debug build and signature verification passed. Host tests cover payload
validation, IPv4/IPv6, QR image generation and decoding, plus existing Host and
address-selection behavior. iOS simulator tests passed (50). Android Debug build,
unit tests and lint passed (27 passed, one external TLS fixture skipped).
Full repository check still reports the five existing legacy SwiftUI aspect-ratio
violations in RepositoryIconImage.swift; changed Host Swift files pass strict lint.
Physical-camera scan/pair acceptance remains for the user; no PR is submitted.
