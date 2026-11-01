// Empty Swift overlay for Darling, built once under each module name in build.sh's
// FORCE_LOAD_ONLY_OVERLAYS. Apps built against the iOS SDK autolink these overlays and import
// only their `__swift_FORCE_LOAD_$_swift<Module>` symbol, which -autolink-force-load emits for
// any module; without an arm64 slice at all, dyld refuses to load the app. The x86_64 slices
// keep their Swift 5.2.2 API. The frameworks behind them are stubs in Darling, so the API the
// Swift 5.2.2 sources add cannot be built against Darling's SDK.
