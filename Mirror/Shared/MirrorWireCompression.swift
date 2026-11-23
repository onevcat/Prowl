import Foundation
import zlib

/// Mirror wire compression (docs-ai 097). A client that sees `deflate-v1` among the Host's
/// capabilities sends `compress`; from then on the Host sends each payload as type `3`: one
/// complete payload of type 0, 1 or 2, compressed with raw DEFLATE and ended with a sync
/// flush. One stream per connection keeps its window across messages, so a pane list that
/// barely changed costs a few dozen bytes. The Mac app and the iOS app compile this file.
nonisolated enum MirrorWireCompression {
  static let capability = "deflate-v1"
  static let payloadType: UInt8 = 3
  /// zlib's raw DEFLATE (no header or checksum), 32 KB window.
  fileprivate static let windowBits: Int32 = -15
  fileprivate static let chunkSize = 64 * 1024

  /// Compresses outgoing payloads in order. Not thread-safe: its connection owns it.
  nonisolated final class Deflater {
    private let stream: UnsafeMutablePointer<z_stream>

    init() throws {
      stream = .allocate(capacity: 1)
      stream.initialize(to: z_stream())
      let status = deflateInit2_(
        stream, 6, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
      guard status == Z_OK else {
        stream.deallocate()
        throw MirrorProtocolError.invalidMessage
      }
    }

    deinit {
      deflateEnd(stream)
      stream.deallocate()
    }

    /// The type-3 payload for `payload`; every byte of it is flushed.
    func compress(_ payload: Data) throws -> Data {
      guard !payload.isEmpty else { throw MirrorProtocolError.invalidMessage }
      var output = Data([payloadType])
      var chunk = [UInt8](repeating: 0, count: chunkSize)
      try payload.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
        stream.pointee.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
        stream.pointee.avail_in = uInt(input.count)
        defer {
          stream.pointee.next_in = nil
          stream.pointee.avail_in = 0
        }
        repeat {
          let produced = try chunk.withUnsafeMutableBufferPointer { buffer in
            stream.pointee.next_out = buffer.baseAddress
            stream.pointee.avail_out = uInt(buffer.count)
            let status = deflate(stream, Z_SYNC_FLUSH)
            guard status == Z_OK || status == Z_BUF_ERROR else { throw MirrorProtocolError.invalidMessage }
            return buffer.count - Int(stream.pointee.avail_out)
          }
          output.append(contentsOf: chunk[0..<produced])
        } while stream.pointee.avail_out == 0
      }
      return output
    }
  }

  /// Decompresses incoming type-3 payloads in order. Not thread-safe: its connection owns it.
  nonisolated final class Inflater {
    private let stream: UnsafeMutablePointer<z_stream>

    init() throws {
      stream = .allocate(capacity: 1)
      stream.initialize(to: z_stream())
      let status = inflateInit2_(stream, windowBits, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
      guard status == Z_OK else {
        stream.deallocate()
        throw MirrorProtocolError.invalidMessage
      }
    }

    deinit {
      inflateEnd(stream)
      stream.deallocate()
    }

    /// The payload inside one type-3 payload (without its type byte). More than `limit` bytes
    /// is an error, so a small frame cannot expand without bound.
    func decompress(_ body: Data, limit: Int) throws -> Data {
      guard !body.isEmpty else { throw MirrorProtocolError.invalidMessage }
      var output = Data()
      var chunk = [UInt8](repeating: 0, count: chunkSize)
      try body.withUnsafeBytes { (input: UnsafeRawBufferPointer) in
        stream.pointee.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
        stream.pointee.avail_in = uInt(input.count)
        defer {
          stream.pointee.next_in = nil
          stream.pointee.avail_in = 0
        }
        while true {
          let (status, produced) = chunk.withUnsafeMutableBufferPointer { buffer in
            stream.pointee.next_out = buffer.baseAddress
            stream.pointee.avail_out = uInt(buffer.count)
            let status = inflate(stream, Z_SYNC_FLUSH)
            return (status, buffer.count - Int(stream.pointee.avail_out))
          }
          // A sender never ends the stream; the end, a dictionary request or bad data is an error.
          guard status == Z_OK || status == Z_BUF_ERROR else { throw MirrorProtocolError.invalidMessage }
          output.append(contentsOf: chunk[0..<produced])
          guard output.count <= limit else { throw MirrorProtocolError.messageTooLarge }
          if stream.pointee.avail_in == 0, stream.pointee.avail_out > 0 { break }
          // No progress with input left: the data is truncated or corrupt.
          if status == Z_BUF_ERROR, produced == 0 { throw MirrorProtocolError.invalidMessage }
        }
      }
      guard !output.isEmpty else { throw MirrorProtocolError.invalidMessage }
      return output
    }
  }

  /// The wire payload as received, inflated when it is type 3. The stream is created on the
  /// first compressed payload, so a connection that never gets one never allocates it.
  static func expand(_ payload: Data, with inflater: inout Inflater?, limit: Int) throws -> Data {
    guard payload.first == payloadType else { return payload }
    let active = try inflater ?? Inflater()
    inflater = active
    let inner = try active.decompress(payload.dropFirst(), limit: limit)
    // One level only: a compressed payload holds a plain one.
    guard inner.first != payloadType else { throw MirrorProtocolError.invalidMessage }
    return inner
  }
}
