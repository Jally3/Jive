import '../../domain/video.dart';
import '../../domain/vod_source.dart';

abstract interface class VodSourceAdapter {
  String get adapterType;

  Future<VideoPage> fetchPage(
    VodSource source, {
    int page = 1,
    int? categoryId,
    String? keyword,
  });

  Future<List<VideoCategory>> fetchCategories(VodSource source);

  Future<Video> fetchDetail(VodSource source, VideoRef ref);

  Future<Video> resolvePlayback(VodSource source, VideoRef ref);
}
