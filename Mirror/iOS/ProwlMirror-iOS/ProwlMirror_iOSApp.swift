//
//  ProwlMirror_iOSApp.swift
//  ProwlMirror-iOS
//
//  Created by Awhisper on 2026/9/9.
//

import SwiftUI

@main
struct ProwlMirror_iOSApp: App {
  @UIApplicationDelegateAdaptor private var appDelegate: MirrorAppDelegate

  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}
