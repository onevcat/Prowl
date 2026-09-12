import Darwin
import Foundation

struct ForegroundProcess: Equatable, Sendable {
  let pid: pid_t
  let parentProcessID: pid_t?
  let name: String
  let argv0: String?
  let cmdline: String?
  let arguments: [String]?

  nonisolated init(
    pid: pid_t,
    parentProcessID: pid_t? = nil,
    name: String,
    argv0: String?,
    cmdline: String?,
    arguments: [String]? = nil
  ) {
    self.pid = pid
    self.parentProcessID = parentProcessID
    self.name = name
    self.argv0 = argv0
    self.cmdline = cmdline
    self.arguments = arguments
  }
}

struct ForegroundJob: Equatable, Sendable {
  let processGroupID: pid_t
  let processes: [ForegroundProcess]

  /// The job member the shell launched on behalf of `pid`: its topmost ancestor
  /// that is still part of this job. A runtime that forks an engine child
  /// (Droid's `droid exec`) moves the identified process while this stays put.
  nonisolated func launchProcessID(of pid: pid_t) -> pid_t {
    var current = pid
    var hops = 0
    while hops < processes.count,
      let parent = processes.first(where: { $0.pid == current })?.parentProcessID,
      processes.contains(where: { $0.pid == parent })
    {
      current = parent
      hops += 1
    }
    return current
  }
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
    let resolvedProcessGroupID: pid_t?
    if let processGroupID, processGroupID > 0 {
      resolvedProcessGroupID = processGroupID
    } else if let childPID, childPID > 0 {
      resolvedProcessGroupID = ProcessDetection.foregroundProcessGroupID(pid: childPID)
    } else {
      resolvedProcessGroupID = nil
    }

    guard let resolvedProcessGroupID else { return nil }
    return cachedForegroundJob(processGroupID: resolvedProcessGroupID, now: Date())
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
        parentProcessID: pid_t(info.pbi_ppid),
        name: name,
        argv0: argv?.first.flatMap(basename),
        cmdline: argv?.joined(separator: " "),
        arguments: argv
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

  static func processStartDate(pid: pid_t) -> Date? {
    guard let info = processBSDInfo(pid: pid), info.pbi_start_tvsec > 0 else { return nil }
    return Date(
      timeIntervalSince1970: TimeInterval(info.pbi_start_tvsec)
        + TimeInterval(info.pbi_start_tvusec) / 1_000_000
    )
  }

  static func openFilePaths(pid: pid_t) -> [String] {
    var complete = false
    return openFilePaths(pid: pid, complete: &complete)
  }

  /// State attribution must reject an incomplete inventory. Existing session
  /// lookup callers can still use the best-effort wrapper above.
  static func openFilePaths(pid: pid_t, complete: inout Bool) -> [String] {
    complete = false
    guard pid > 0 else { return [] }
    var capacity = 256
    var descriptors: [proc_fdinfo] = []
    var count = 0
    while capacity <= 4_096 {
      descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
      let filled = descriptors.withUnsafeMutableBytes { buffer in
        proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
      }
      guard filled > 0 else { return [] }
      count = Int(filled) / MemoryLayout<proc_fdinfo>.stride
      if count < capacity { break }
      capacity *= 2
    }
    complete = count < descriptors.count

    return descriptors.prefix(count).compactMap { descriptor -> String? in
      guard descriptor.proc_fdtype == PROX_FDTYPE_VNODE else { return nil }
      var info = vnode_fdinfowithpath()
      let size = MemoryLayout<vnode_fdinfowithpath>.size
      let result = withUnsafeMutablePointer(to: &info) { pointer in
        proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDVNODEPATHINFO, pointer, Int32(size))
      }
      guard result == Int32(size) else {
        complete = false
        return nil
      }
      // Only writable descriptors identify a session an agent OWNS. Agents
      // transiently open other sessions read-only (resume pickers, history
      // browsing); every legitimate signal (Codex rollout, Amp thread log,
      // Cursor store.db) is open for writing.
      guard info.pfi.fi_openflags & UInt32(FWRITE) != 0 else { return nil }
      return withUnsafeBytes(of: info.pvip.vip_path) { rawBuffer -> String? in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        guard end > bytes.startIndex, end < bytes.endIndex,
          let path = String(bytes: bytes[..<end], encoding: .utf8)
        else {
          complete = false
          return nil
        }
        return path
      }
    }
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
