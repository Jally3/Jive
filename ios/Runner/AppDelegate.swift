import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "jive/cache",
        binaryMessenger: controller.binaryMessenger)
      channel.setMethodCallHandler { call, result in
        let fileManager = FileManager.default
        let url = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        switch call.method {
        case "totalCapacityBytes":
          if let value = try? url?.resourceValues(
            forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity {
            result(Int64(value))
          } else {
            result(nil)
          }
        case "availableBytes":
          if let value = try? url?.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
          ).volumeAvailableCapacityForImportantUsage {
            result(Int64(value))
          } else {
            result(0)
          }
        case "platformCacheLimitBytes":
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
