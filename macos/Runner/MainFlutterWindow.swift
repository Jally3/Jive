import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)
    registerJiveChannels(messenger: flutterViewController.engine.binaryMessenger)

    super.awakeFromNib()
  }

  /// 与 android MainActivity.kt 对等的平台通道。
  private func registerJiveChannels(messenger: FlutterBinaryMessenger) {
    // 桌面不是电视，恒 false。
    let device = FlutterMethodChannel(name: "jive/device", binaryMessenger: messenger)
    device.setMethodCallHandler { call, result in
      if call.method == "isTelevision" {
        result(false)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    // 磁盘容量：对应 Android 的 StatFs；macOS 无平台级缓存配额概念，返回 nil。
    let cache = FlutterMethodChannel(name: "jive/cache", binaryMessenger: messenger)
    cache.setMethodCallHandler { call, result in
      switch call.method {
      case "totalCapacityBytes", "availableBytes":
        result(Self.fileSystemSize(forTotal: call.method == "totalCapacityBytes"))
      case "platformCacheLimitBytes":
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func fileSystemSize(forTotal: Bool) -> Int64? {
    guard
      let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
      let attrs = try? FileManager.default.attributesOfFileSystem(forPath: home.path)
    else { return nil }
    let key: FileAttributeKey = forTotal ? .systemSize : .systemFreeSize
    return (attrs[key] as? NSNumber)?.int64Value
  }
}
