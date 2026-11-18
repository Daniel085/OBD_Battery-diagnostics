import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // lib/app/keep_awake.dart: no auto-lock while connected to an adapter.
    let screen = FlutterMethodChannel(
      name: "obd_battery_diagnostics/screen",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())
    screen.setMethodCallHandler { call, result in
      if call.method == "keepAwake", let on = call.arguments as? Bool {
        UIApplication.shared.isIdleTimerDisabled = on
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
