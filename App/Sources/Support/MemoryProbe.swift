import Darwin.Mach
import Foundation

/// Reads the current process's physical memory footprint in megabytes.
///
/// Uses `phys_footprint` from `task_info(TASK_VM_INFO)` — the same value
/// Activity Monitor reports for "Memory" and Apple's recommended metric for
/// "real RAM pressure this app contributes" (it folds in compressed memory).
nonisolated enum MemoryProbe {
  static func physFootprintMegabytes() -> Int {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
      }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Int(info.phys_footprint / (1024 * 1024))
  }
}
