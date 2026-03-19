import CoreGraphics
import Foundation
import Testing

@testable import supacode

struct CanvasTabNavigatorTests {
  private func entry(
    _ id: String,
    x: CGFloat,
    y: CGFloat,
    width: CGFloat = 100,
    height: CGFloat = 100
  ) -> CanvasTabNavigator.Entry<String> {
    CanvasTabNavigator.Entry(
      id: id,
      center: CGPoint(x: x, y: y),
      size: CGSize(width: width, height: height)
    )
  }

  @Test func leftRightDoesNotMoveInVerticalStack() {
    let tabs = [
      entry("top", x: 100, y: 100),
      entry("mid", x: 100, y: 240),
      entry("bottom", x: 100, y: 380),
    ]

    #expect(CanvasTabNavigator.nextID(from: "mid", direction: .left, entries: tabs) == nil)
    #expect(CanvasTabNavigator.nextID(from: "mid", direction: .right, entries: tabs) == nil)
  }

  @Test func upDownDoesNotMoveInHorizontalRow() {
    let tabs = [
      entry("left", x: 100, y: 120),
      entry("mid", x: 240, y: 120),
      entry("right", x: 380, y: 120),
    ]

    #expect(CanvasTabNavigator.nextID(from: "mid", direction: .up, entries: tabs) == nil)
    #expect(CanvasTabNavigator.nextID(from: "mid", direction: .down, entries: tabs) == nil)
  }

  @Test func rightPrefersNearestCandidateWithinSameRow() {
    let tabs = [
      entry("current", x: 100, y: 100),
      entry("near", x: 240, y: 100),
      entry("far", x: 420, y: 110),
      entry("offAxis", x: 260, y: 320),
    ]

    #expect(CanvasTabNavigator.nextID(from: "current", direction: .right, entries: tabs) == "near")
    let target = CanvasTabNavigator.nextTarget(from: "current", direction: .right, entries: tabs)
    #expect(target?.id == "near")
    #expect(target?.didWrap == false)
  }

  @Test func horizontalWrapStaysWithinHorizontalAxis() {
    let tabs = [
      entry("left", x: 100, y: 100),
      entry("right", x: 260, y: 100),
      entry("lower", x: 120, y: 340),
    ]

    #expect(CanvasTabNavigator.nextID(from: "left", direction: .left, entries: tabs) == "right")
    #expect(CanvasTabNavigator.nextID(from: "right", direction: .right, entries: tabs) == "left")
    let leftWrapTarget = CanvasTabNavigator.nextTarget(from: "left", direction: .left, entries: tabs)
    #expect(leftWrapTarget?.id == "right")
    #expect(leftWrapTarget?.didWrap == true)

    let rightWrapTarget = CanvasTabNavigator.nextTarget(from: "right", direction: .right, entries: tabs)
    #expect(rightWrapTarget?.id == "left")
    #expect(rightWrapTarget?.didWrap == true)
  }

  @Test func verticalWrapStaysWithinVerticalAxis() {
    let tabs = [
      entry("top", x: 100, y: 100),
      entry("bottom", x: 100, y: 280),
      entry("right", x: 320, y: 120),
    ]

    #expect(CanvasTabNavigator.nextID(from: "top", direction: .up, entries: tabs) == "bottom")
    #expect(CanvasTabNavigator.nextID(from: "bottom", direction: .down, entries: tabs) == "top")
    let upWrapTarget = CanvasTabNavigator.nextTarget(from: "top", direction: .up, entries: tabs)
    #expect(upWrapTarget?.id == "bottom")
    #expect(upWrapTarget?.didWrap == true)

    let downWrapTarget = CanvasTabNavigator.nextTarget(from: "bottom", direction: .down, entries: tabs)
    #expect(downWrapTarget?.id == "top")
    #expect(downWrapTarget?.didWrap == true)
  }

  @Test func downFallsBackToDirectionalCandidateWhenAxisAlignedIsEmpty() {
    let tabs = [
      entry("1", x: 400, y: 289, width: 800, height: 578),
      entry("2", x: 1220, y: 289, width: 800, height: 578),
      entry("3", x: 400, y: 887, width: 800, height: 578),
    ]

    #expect(CanvasTabNavigator.nextID(from: "2", direction: .down, entries: tabs) == "3")
  }

  @Test func upFallsBackToDirectionalCandidateWhenAxisAlignedIsEmpty() {
    let tabs = [
      entry("1", x: 400, y: 289, width: 800, height: 578),
      entry("3", x: 400, y: 887, width: 800, height: 578),
      entry("4", x: 1220, y: 887, width: 800, height: 578),
    ]

    #expect(CanvasTabNavigator.nextID(from: "4", direction: .up, entries: tabs) == "1")
  }
}
