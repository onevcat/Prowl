import Darwin
import Foundation

struct ForegroundProcess: Equatable, Sendable {
  let pid: pid_t
  let name: String
  let argv0: String?
  let cmdline: String?
}

struct ForegroundJob: Equatable, Sendable {
  let processGroupID: pid_t
  let processes: [ForegroundProcess]
}

actor AgentProcessProbe {
  static let shared = AgentProcessProbe()

  private struct CachedJob {
    let capturedAt: Date
    let job: ForegroundJob?
  }

  private let cacheLifetime: TimeInterval
  private var jobsByProcessGroupID: [pid_t: CachedJob] = [:]

  init(cacheLifetime: TimeInterval = 0.75) {
    self.cacheLifetime = cacheLifetime
  }

  func foregroundJob(processGroupID: pid_t?, childPID: pid_t?) -> ForegroundJob? {
    guard let resolvedProcessGroupID = resolveProcessGroupID(processGroupID: processGroupID, childPID: childPID) else {
      return nil
    }
    return cachedForegroundJob(processGroupID: resolvedProcessGroupID, now: Date())
  }

  func refreshForegroundJob(processGroupID: pid_t?, childPID: pid_t?) -> ForegroundJob? {
    guard let resolvedProcessGroupID = resolveProcessGroupID(processGroupID: processGroupID, childPID: childPID) else {
      return nil
    }
    return ProcessDetection.foregroundJob(processGroupID: resolvedProcessGroupID)
  }

  private func resolveProcessGroupID(processGroupID: pid_t?, childPID: pid_t?) -> pid_t? {
    if let processGroupID, processGroupID > 0 {
      return processGroupID
    } else if let childPID, childPID > 0 {
      return ProcessDetection.foregroundProcessGroupID(pid: childPID)
    }
    return nil
  }

  private func cachedForegroundJob(processGroupID: pid_t, now: Date) -> ForegroundJob? {
    if let cached = jobsByProcessGroupID[processGroupID],
      now.timeIntervalSince(cached.capturedAt) < cacheLifetime
    {
      return cached.job
    }

    let job = ProcessDetection.foregroundJob(processGroupID: processGroupID)
    jobsByProcessGroupID[processGroupID] = CachedJob(capturedAt: now, job: job)
    removeExpiredJobs(now: now)
    return job
  }

  private func removeExpiredJobs(now: Date) {
    guard jobsByProcessGroupID.count > 64 else { return }
    jobsByProcessGroupID = jobsByProcessGroupID.filter { _, cached in
      now.timeIntervalSince(cached.capturedAt) < cacheLifetime
    }
  }
}

nonisolated enum ProcessDetection {
  static func foregroundJob(childPID: pid_t) -> ForegroundJob? {
    guard childPID > 0, let processGroupID = foregroundProcessGroupID(pid: childPID) else {
      return nil
    }
    return foregroundJob(processGroupID: processGroupID)
  }

  static func foregroundJob(processGroupID: pid_t) -> ForegroundJob? {
    guard processGroupID > 0 else { return nil }
    let processes = processGroupPIDs(processGroupID).compactMap { pid -> ForegroundProcess? in
      guard pid > 0,
        let info = processBSDInfo(pid: pid),
        let name = comm(from: info)
      else {
        return nil
      }
      let argv = processArguments(pid: pid)
      return ForegroundProcess(
        pid: pid,
        name: name,
        argv0: argv?.first.flatMap(basename),
        cmdline: argv?.joined(separator: " ")
      )
    }

    guard !processes.isEmpty else { return nil }
    return ForegroundJob(processGroupID: processGroupID, processes: processes)
  }

  static func processGroupPIDs(_ processGroupID: pid_t) -> [pid_t] {
    guard processGroupID > 0 else { return [] }
    var capacity = 16

    while capacity <= 4096 {
      var pids = [pid_t](repeating: 0, count: capacity)
      let bytes = pids.withUnsafeMutableBufferPointer { buffer in
        proc_listpids(
          UInt32(PROC_PGRP_ONLY),
          UInt32(processGroupID),
          buffer.baseAddress,
          Int32(buffer.count * MemoryLayout<pid_t>.size)
        )
      }
      guard bytes > 0 else { return [] }

      let count = Int(bytes) / MemoryLayout<pid_t>.size
      let result = pids.prefix(count).filter { $0 > 0 }
      if count < capacity {
        return Array(result)
      }
      capacity *= 2
    }

    return []
  }

  static func foregroundProcessGroupID(pid: pid_t) -> pid_t? {
    guard let info = processBSDInfo(pid: pid), info.e_tpgid > 0 else {
      return nil
    }
    return pid_t(info.e_tpgid)
  }

  static func processCommandLine(pid: pid_t) -> String? {
    processArguments(pid: pid)?.joined(separator: " ")
  }

  static func processArgv0Name(pid: pid_t) -> String? {
    guard let argv0 = processArguments(pid: pid)?.first else {
      return nil
    }
    return basename(argv0)
  }

  static func processArguments(pid: pid_t) -> [String]? {
    guard let buffer = kernProcargs2(pid: pid) else {
      return nil
    }
    return procargs2Argv(buffer)
  }

  static func processBSDInfo(pid: pid_t) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let size = MemoryLayout<proc_bsdinfo>.size
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
    }
    return result == Int32(size) ? info : nil
  }

  static func comm(from info: proc_bsdinfo) -> String? {
    let bytes = withUnsafeBytes(of: info.pbi_comm) { rawBuffer -> [UInt8] in
      Array(rawBuffer)
    }
    let end = bytes.firstIndex(of: 0) ?? bytes.count
    guard end > 0 else { return nil }
    return String(bytes: bytes[..<end], encoding: .utf8)
  }

  static func kernProcargs2(pid: pid_t) -> [UInt8]? {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
      return nil
    }

    var buffer = [UInt8](repeating: 0, count: size)
    let result = buffer.withUnsafeMutableBufferPointer { pointer in
      sysctl(&mib, u_int(mib.count), pointer.baseAddress, &size, nil, 0)
    }
    guard result == 0 else { return nil }
    return Array(buffer.prefix(size))
  }

  static func procargs2Argv(_ buffer: [UInt8]) -> [String]? {
    guard buffer.count >= MemoryLayout<Int32>.size else { return nil }
    let argc = buffer.withUnsafeBytes { rawBuffer in
      rawBuffer.loadUnaligned(as: Int32.self)
    }
    guard argc > 0 else { return nil }

    var position = MemoryLayout<Int32>.size
    guard let execEnd = buffer[position...].firstIndex(of: 0) else { return nil }
    position = execEnd
    while position < buffer.count, buffer[position] == 0 {
      position += 1
    }

    var argv: [String] = []
    while position < buffer.count, argv.count < Int(argc) {
      let start = position
      while position < buffer.count, buffer[position] != 0 {
        position += 1
      }
      if position > start, let value = String(bytes: buffer[start..<position], encoding: .utf8) {
        argv.append(value)
      }
      while position < buffer.count, buffer[position] == 0 {
        position += 1
      }
    }

    return argv.isEmpty ? nil : argv
  }

  static func basename(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    guard !trimmed.isEmpty else { return nil }
    let name = (trimmed as NSString).lastPathComponent
    let stripped = name.hasPrefix("-") ? String(name.dropFirst()) : name
    return stripped.isEmpty ? nil : stripped
  }
}
