import AppKit
import SwiftUI
import Testing

@testable import supacode

@MainActor
struct AgentIslandHoverAnimationTests {
  @Test func hoverAnimatesButRosterLayoutDoesNotReplayIt() {
    let fixture = HoverAnimationFixture()
    defer { fixture.close() }

    fixture.updateHover(true)
    #expect(fixture.samples.allSatisfy { $0.contains { $0 > 0 && $0 < 1 } })
    #expect(fixture.samples.allSatisfy { $0.last == 1 })

    for expanded in [true, false] {
      fixture.updateRoster(expanded)
      #expect(fixture.samples.allSatisfy { $0.allSatisfy { $0 == 1 } })
    }

    fixture.updateHover(false)
    #expect(fixture.samples.allSatisfy { $0.contains { $0 > 0 && $0 < 1 } })
    #expect(fixture.samples.allSatisfy { $0.last == 0 })
  }

  @Test func reduceMotionMakesHoverImmediate() {
    let fixture = HoverAnimationFixture()
    defer { fixture.close() }

    fixture.updateHover(true, reduceMotion: true)
    #expect(fixture.samples.allSatisfy { !$0.contains { $0 > 0 && $0 < 1 } })
    #expect(fixture.samples.allSatisfy { $0.last == 1 })
  }
}

@MainActor
private final class HoverAnimationFixture {
  @Observable final class Model {
    var hovered = false
    var expanded = false
  }

  final class Recorder {
    var samples: [Double] = []
  }

  private struct ProgressProbe: AnimatableModifier {
    var progress: Double
    let recorder: Recorder

    var animatableData: Double {
      get { progress }
      set {
        progress = newValue
        recorder.samples.append(newValue)
      }
    }

    func body(content: Content) -> some View {
      recorder.samples.append(progress)
      return content.opacity(progress).offset(x: progress * 28)
    }
  }

  private struct Host: View {
    let model: Model
    let recorder: Recorder
    let gripRecorder: Recorder

    var body: some View {
      VStack {
        Button {
        } label: {
          Color.white.frame(width: 80, height: 30)
            .modifier(ProgressProbe(progress: model.hovered ? 1 : 0, recorder: recorder))
            .transaction(AgentIslandHoverAnimation.apply)
            .frame(width: 340, height: 40)
        }
        .buttonStyle(.plain)
        .background(.black)
        .overlay(alignment: .leading) {
          Color.white.frame(width: 24, height: 20)
            .modifier(ProgressProbe(progress: model.hovered ? 1 : 0, recorder: gripRecorder))
            .transaction(AgentIslandHoverAnimation.apply)
            .allowsHitTesting(model.hovered)
        }
        if model.expanded {
          Color.clear.frame(height: 100)
        }
      }
      .frame(width: model.expanded ? 420 : 340)
      .transaction { $0.animation = nil }
    }
  }

  private let model = Model()
  private let recorder = Recorder()
  private let gripRecorder = Recorder()
  private let window: NSWindow
  private let host: NSHostingView<Host>
  var samples: [[Double]] { [recorder.samples, gripRecorder.samples] }

  init() {
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 420, height: 200),
      styleMask: [.borderless], backing: .buffered, defer: false
    )
    host = NSHostingView(rootView: Host(model: model, recorder: recorder, gripRecorder: gripRecorder))
    window.contentView = host
    window.orderBack(nil)
    render()
  }

  func close() {
    window.orderOut(nil)
  }

  func updateHover(_ hovered: Bool, reduceMotion: Bool = false) {
    recorder.samples = []
    gripRecorder.samples = []
    AgentIslandHoverAnimation.perform(reduceMotion: reduceMotion) {
      model.hovered = hovered
    }
    render()
  }

  func updateRoster(_ expanded: Bool) {
    recorder.samples = []
    gripRecorder.samples = []
    model.expanded = expanded
    render()
  }

  private func render() {
    // Exercise SwiftUI's real presentation frames; a TestClock cannot drive AppKit rendering.
    let deadline = Date().addingTimeInterval(0.35)
    while Date() < deadline {
      RunLoop.main.run(until: Date().addingTimeInterval(0.01))
      host.layoutSubtreeIfNeeded()
      host.displayIfNeeded()
    }
  }
}
