// ProwlShared/OutputMode.swift
// Shared between CLI and App targets

import Foundation

public enum OutputMode: String, Codable, Sendable {
  case text
  case json
}
