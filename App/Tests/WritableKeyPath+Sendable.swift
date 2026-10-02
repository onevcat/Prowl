#if compiler(>=6)
  // swift-format-ignore: AvoidRetroactiveConformances
  extension WritableKeyPath: @retroactive @unchecked Sendable {}
#endif
