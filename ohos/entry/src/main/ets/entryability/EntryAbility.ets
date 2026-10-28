
import statfs from '@ohos.file.statvfs';
import { FlutterAbility, FlutterEngine, MethodCall, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine);
    GeneratedPluginRegistrant.registerWith(flutterEngine);
    const cacheChannel = new MethodChannel(
      flutterEngine.getDartExecutor().getBinaryMessenger(), 'jive/cache');
    cacheChannel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult): void => {
        try {
          // Query the application data filesystem, rather than the system partition.
          switch (call.method) {
            case 'totalCapacityBytes':
              result.success(statfs.getTotalSizeSync(this.context.filesDir));
              break;
            case 'availableBytes':
              result.success(statfs.getFreeSizeSync(this.context.filesDir));
              break;
            case 'platformCacheLimitBytes':
              result.success(null);
              break;
            default:
              result.notImplemented();
          }
        } catch (error) {
          result.error('disk_space_unavailable', '无法读取存储空间', null);
        }
      }
    });
  }
}
