/// Explicit independent release flavor; ordinary source builds keep upstream
/// behavior. CI verifies this flag alongside the Rust bridge release feature.
const isolatedFlutterRelease = bool.fromEnvironment('XENTERM_FLUTTER_NEXT');
