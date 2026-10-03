import Foundation

#if DEBUG

  /// Sidebar entries for the Debug Window. Add a case here, an entry
  /// in `DebugView`'s sidebar list, and a switch arm in the detail
  /// area to register a new debug surface.
  enum DebugSection: Hashable {
    /// Catalogue of every `CommandIconMap` entry alongside its rendered
    /// icon. Lets us eyeball the auto-detected tab-icon set after
    /// adding new branded artwork or sanity-checking that an asset
    /// actually paints in the SwiftUI runtime.
    case iconCatalog
  }

#endif
