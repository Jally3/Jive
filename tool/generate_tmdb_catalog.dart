import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

const _baseUrl = 'https://api.themoviedb.org/3';
const _animationGenre = 16;
const _varietyGenres = {10763, 10764, 10767};

Future<void> main(List<String> arguments) async {
  var token = Platform.environment['TMDB_READ_ACCESS_TOKEN']?.trim() ?? '';
  final tokenFile = File(_argument(arguments, '--token-file') ?? '.tmdb-token');
  if (token.isEmpty && await tokenFile.exists()) {
    token = (await tokenFile.readAsString()).trim();
  }
  if (token.isEmpty) {
    stderr.writeln('缺少 TMDB_READ_ACCESS_TOKEN，且未找到 .tmdb-token');
    exitCode = 64;
    return;
  }
  final output = _argument(arguments, '--output') ?? 'build/tmdb_catalog';
  final pages = int.tryParse(_argument(arguments, '--pages') ?? '10') ?? 10;
  if (pages < 1 || pages > 20) {
    stderr.writeln('--pages 必须在 1..20');
    exitCode = 64;
    return;
  }

  final proxy =
      _argument(arguments, '--proxy') ??
      Platform.environment['HTTPS_PROXY'] ??
      Platform.environment['https_proxy'];
  final client = _createClient(proxy);
  final api = _TmdbApi(client, token);
  try {
    final now = DateTime.now().toUtc();
    final revision = _revision(now);
    final start = now.subtract(const Duration(days: 180));
    final snapshots = <String, Map<String, dynamic>>{};
    snapshots['latest'] = await _buildLatest(api, pages, start, now);
    snapshots['popular'] = await _buildPopular(api, pages);
    snapshots['top_rated'] = await _buildTopRated(api, pages);

    await Directory(output).create(recursive: true);
    final manifestFeeds = <String, dynamic>{};
    for (final entry in snapshots.entries) {
      final fileName = entry.key == 'top_rated'
          ? 'top-rated.json'
          : '${entry.key}.json';
      final generated = _snapshotJson(entry.key, revision, entry.value);
      _validateSnapshot(generated);
      await _writeJson(File('$output/$fileName'), generated);
      final ttl = entry.key == 'top_rated'
          ? const Duration(hours: 24)
          : const Duration(hours: 6);
      manifestFeeds[entry.key] = {
        'revision': revision,
        'generatedAt': now.toIso8601String(),
        'expiresAt': now.add(ttl).toIso8601String(),
        'path': fileName,
      };
    }
    final manifest = {
      'schemaVersion': 1,
      'language': 'zh-CN',
      'feeds': manifestFeeds,
    };
    await _writeJson(File('$output/manifest.json'), manifest);
    stdout.writeln('已生成 $output（revision $revision）');
  } finally {
    client.close();
  }
}

http.Client _createClient(String? proxyValue) {
  final value = proxyValue?.trim() ?? '';
  if (value.isEmpty) return http.Client();
  final proxy = Uri.tryParse(value);
  if (proxy == null ||
      proxy.scheme != 'http' ||
      proxy.host.isEmpty ||
      !proxy.hasPort ||
      proxy.userInfo.isNotEmpty) {
    throw const FormatException(
      '--proxy 必须是不含凭据的 HTTP 地址，例如 http://127.0.0.1:1087',
    );
  }
  final ioClient = HttpClient();
  ioClient.findProxy = (_) => 'PROXY ${proxy.host}:${proxy.port}';
  return IOClient(ioClient);
}

Future<Map<String, dynamic>> _buildPopular(_TmdbApi api, int pages) async {
  final items = <_CatalogItem>[];
  for (var page = 1; page <= pages; page++) {
    final responses = await Future.wait([
      api.list('/trending/movie/week', page: page),
      api.list('/trending/tv/week', page: page),
    ]);
    items.addAll(
      responses[0].map((json) => _CatalogItem.fromTmdb(json, 'movie')),
    );
    items.addAll(responses[1].map((json) => _CatalogItem.fromTmdb(json, 'tv')));
  }
  return _groups(items, _comparePopular);
}

Future<Map<String, dynamic>> _buildTopRated(_TmdbApi api, int pages) async {
  final items = <_CatalogItem>[];
  for (var page = 1; page <= pages; page++) {
    final responses = await Future.wait([
      api.list(
        '/discover/movie',
        page: page,
        query: {
          'include_adult': 'false',
          'include_video': 'false',
          'sort_by': 'vote_average.desc',
          'vote_average.gte': '7.0',
          'vote_count.gte': '200',
        },
      ),
      api.list(
        '/discover/tv',
        page: page,
        query: {
          'include_adult': 'false',
          'sort_by': 'vote_average.desc',
          'vote_average.gte': '7.0',
          'vote_count.gte': '200',
        },
      ),
    ]);
    items.addAll(
      responses[0].map((json) => _CatalogItem.fromTmdb(json, 'movie')),
    );
    items.addAll(responses[1].map((json) => _CatalogItem.fromTmdb(json, 'tv')));
  }
  return _groups(items, _compareTopRated);
}

Future<Map<String, dynamic>> _buildLatest(
  _TmdbApi api,
  int pages,
  DateTime start,
  DateTime now,
) async {
  final items = <_CatalogItem>[];
  final onAir = <_CatalogItem>[];
  for (var page = 1; page <= pages; page++) {
    final responses = await Future.wait([
      api.list(
        '/discover/movie',
        page: page,
        query: {
          'include_adult': 'false',
          'include_video': 'false',
          'sort_by': 'popularity.desc',
          'primary_release_date.gte': _date(start),
          'primary_release_date.lte': _date(now),
        },
      ),
      api.list(
        '/discover/tv',
        page: page,
        query: {
          'include_adult': 'false',
          'sort_by': 'popularity.desc',
          'first_air_date.gte': _date(start),
          'first_air_date.lte': _date(now),
        },
      ),
      api.list('/tv/on_the_air', page: page),
    ]);
    items.addAll(
      responses[0].map((json) => _CatalogItem.fromTmdb(json, 'movie')),
    );
    items.addAll(responses[1].map((json) => _CatalogItem.fromTmdb(json, 'tv')));
    onAir.addAll(responses[2].map((json) => _CatalogItem.fromTmdb(json, 'tv')));
  }

  final uniqueOnAir = _dedupe(onAir).take(200).toList();
  final detailed = await _mapConcurrent(uniqueOnAir, 4, (item) async {
    try {
      final detail = await api.detail('/tv/${item.tmdbId}');
      final episode = detail['last_episode_to_air'];
      final episodeMap = episode is Map ? episode : const {};
      return item.copyWith(
        sortDate: '${episodeMap['air_date'] ?? item.sortDate}',
        latestSeasonNumber: _positiveInt(episodeMap['season_number']),
      );
    } catch (_) {
      return item;
    }
  });
  items.addAll(detailed);
  // Discover 按日期倒序会被零热度的个人短片、测试条目甚至
  // 垃圾标题占据。“最新”仍按日期排序，但先加一个低热度质量门槛。
  return _groups(
    items.where((item) => item.popularity >= 10).toList(),
    _compareLatest,
  );
}

Map<String, dynamic> _groups(
  List<_CatalogItem> input,
  int Function(_CatalogItem, _CatalogItem) compare,
) {
  final unique = _dedupe(input)..sort(compare);
  List<_CatalogItem> select(bool Function(_CatalogItem) test) =>
      unique.where(test).take(200).toList(growable: false);
  final groups = <String, List<_CatalogItem>>{
    'all': select((_) => true),
    'movie': select((item) => item.category == 'movie'),
    'tv': select((item) => item.category == 'tv'),
    'animation': select((item) => item.category == 'animation'),
    'variety': select((item) => item.category == 'variety'),
  };
  final dictionary = <String, _CatalogItem>{};
  for (final group in groups.values) {
    for (final item in group) {
      dictionary[item.globalId] = item;
    }
  }
  return {
    'groups': {
      for (final entry in groups.entries)
        entry.key: entry.value.map((item) => item.globalId).toList(),
    },
    'items': {
      for (final entry in dictionary.entries) entry.key: entry.value.toJson(),
    },
  };
}

Map<String, dynamic> _snapshotJson(
  String feed,
  String revision,
  Map<String, dynamic> data,
) => {'schemaVersion': 1, 'revision': revision, 'feed': feed, ...data};

void _validateSnapshot(Map<String, dynamic> snapshot) {
  final groups = snapshot['groups'];
  final items = snapshot['items'];
  if (groups is! Map || items is! Map || items.isEmpty) {
    throw const FormatException('拒绝发布空榜单');
  }
  for (final name in const ['all', 'movie', 'tv', 'animation', 'variety']) {
    final ids = groups[name];
    if (ids is! List || ids.length > 200 || ids.toSet().length != ids.length) {
      throw FormatException('榜单分组无效：$name');
    }
    if (ids.any((id) => !items.containsKey(id))) {
      throw FormatException('榜单分组引用缺失：$name');
    }
  }
  if ((groups['all'] as List).isEmpty) {
    throw const FormatException('拒绝发布无全部内容的榜单');
  }
}

class _TmdbApi {
  _TmdbApi(this.client, this.token);
  final http.Client client;
  final String token;

  Future<List<Map<String, dynamic>>> list(
    String path, {
    required int page,
    Map<String, String> query = const {},
  }) async {
    final json = await _get(path, {
      'language': 'zh-CN',
      'page': '$page',
      ...query,
    });
    final results = json['results'];
    if (results is! List) throw const FormatException('TMDB results 无效');
    return results.whereType<Map>().map(Map<String, dynamic>.from).toList();
  }

  Future<Map<String, dynamic>> detail(String path) =>
      _get(path, const {'language': 'zh-CN'});

  Future<Map<String, dynamic>> _get(
    String path,
    Map<String, String> query,
  ) async {
    final uri = Uri.parse('$_baseUrl$path').replace(queryParameters: query);
    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        final response = await client
            .get(
              uri,
              headers: {
                'Authorization': 'Bearer $token',
                'Accept': 'application/json',
              },
            )
            .timeout(const Duration(seconds: 30));
        if (response.statusCode == 200) {
          final decoded = jsonDecode(utf8.decode(response.bodyBytes));
          if (decoded is! Map) throw const FormatException('TMDB JSON 无效');
          return Map<String, dynamic>.from(decoded);
        }
        final retryable =
            response.statusCode == 429 || response.statusCode >= 500;
        if (!retryable || attempt == 3) {
          throw HttpException('TMDB ${response.statusCode}: $path');
        }
        final retryAfter = int.tryParse(response.headers['retry-after'] ?? '');
        await Future<void>.delayed(
          Duration(seconds: (retryAfter ?? attempt).clamp(1, 10)),
        );
      } on TimeoutException catch (error) {
        lastError = error;
        if (attempt == 3) rethrow;
        await Future<void>.delayed(Duration(seconds: attempt));
      } on SocketException catch (error) {
        lastError = error;
        if (attempt == 3) rethrow;
        await Future<void>.delayed(Duration(seconds: attempt));
      }
    }
    throw HttpException('TMDB 请求失败：$path ($lastError)');
  }
}

class _CatalogItem {
  const _CatalogItem({
    required this.tmdbId,
    required this.mediaType,
    required this.category,
    required this.localizedTitle,
    required this.originalTitle,
    required this.releaseDate,
    required this.sortDate,
    required this.rating,
    required this.voteCount,
    required this.popularity,
    required this.posterPath,
    this.latestSeasonNumber,
  });

  factory _CatalogItem.fromTmdb(Map<String, dynamic> json, String mediaType) {
    final genres = _intSet(json['genre_ids']);
    final category = genres.contains(_animationGenre)
        ? 'animation'
        : mediaType == 'tv' && genres.any(_varietyGenres.contains)
        ? 'variety'
        : mediaType;
    final releaseDate =
        '${json[mediaType == 'movie' ? 'release_date' : 'first_air_date'] ?? ''}';
    return _CatalogItem(
      tmdbId: json['adult'] == true ? 0 : _int(json['id']),
      mediaType: mediaType,
      category: category,
      localizedTitle: '${json[mediaType == 'movie' ? 'title' : 'name'] ?? ''}',
      originalTitle:
          '${json[mediaType == 'movie' ? 'original_title' : 'original_name'] ?? ''}',
      releaseDate: releaseDate,
      sortDate: releaseDate,
      rating: _double(json['vote_average']),
      voteCount: _int(json['vote_count']),
      popularity: _double(json['popularity']),
      posterPath: '${json['poster_path'] ?? ''}',
    );
  }

  final int tmdbId;
  final String mediaType;
  final String category;
  final String localizedTitle;
  final String originalTitle;
  final String releaseDate;
  final String sortDate;
  final int? latestSeasonNumber;
  final double rating;
  final int voteCount;
  final double popularity;
  final String posterPath;

  String get globalId => 'tmdb:$mediaType:$tmdbId';

  _CatalogItem copyWith({String? sortDate, int? latestSeasonNumber}) =>
      _CatalogItem(
        tmdbId: tmdbId,
        mediaType: mediaType,
        category: category,
        localizedTitle: localizedTitle,
        originalTitle: originalTitle,
        releaseDate: releaseDate,
        sortDate: sortDate ?? this.sortDate,
        latestSeasonNumber: latestSeasonNumber ?? this.latestSeasonNumber,
        rating: rating,
        voteCount: voteCount,
        popularity: popularity,
        posterPath: posterPath,
      );

  Map<String, dynamic> toJson() => {
    'tmdbId': tmdbId,
    'mediaType': mediaType,
    'category': category,
    'localizedTitle': localizedTitle,
    'originalTitle': originalTitle,
    'aliases': const <String>[],
    'releaseDate': releaseDate,
    'sortDate': sortDate,
    if (latestSeasonNumber != null) 'latestSeasonNumber': latestSeasonNumber,
    'rating': rating,
    'voteCount': voteCount,
    'popularity': popularity,
    'posterPath': posterPath,
  };
}

List<_CatalogItem> _dedupe(List<_CatalogItem> items) {
  final byId = <String, _CatalogItem>{};
  for (final item in items) {
    if (item.tmdbId <= 0 ||
        (item.localizedTitle.trim().isEmpty &&
            item.originalTitle.trim().isEmpty)) {
      continue;
    }
    final previous = byId[item.globalId];
    if (previous == null || item.sortDate.compareTo(previous.sortDate) > 0) {
      byId[item.globalId] = item;
    }
  }
  return byId.values.toList();
}

int _comparePopular(_CatalogItem a, _CatalogItem b) =>
    b.popularity.compareTo(a.popularity);
int _compareLatest(_CatalogItem a, _CatalogItem b) =>
    b.sortDate.compareTo(a.sortDate);
int _compareTopRated(_CatalogItem a, _CatalogItem b) {
  final score = b.rating.compareTo(a.rating);
  return score != 0 ? score : b.voteCount.compareTo(a.voteCount);
}

Future<List<R>> _mapConcurrent<T, R>(
  List<T> values,
  int concurrency,
  Future<R> Function(T value) action,
) async {
  if (values.isEmpty) return const [];
  final results = List<R?>.filled(values.length, null);
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final index = next++;
      if (index >= values.length) return;
      results[index] = await action(values[index]);
    }
  }

  await Future.wait(
    List.generate(concurrency.clamp(1, values.length), (_) => worker()),
  );
  return results.cast<R>();
}

Future<void> _writeJson(File file, Map<String, dynamic> value) async {
  await file.parent.create(recursive: true);
  await file.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(value)}\n',
  );
}

String? _argument(List<String> arguments, String name) {
  final index = arguments.indexOf(name);
  return index >= 0 && index + 1 < arguments.length
      ? arguments[index + 1]
      : null;
}

String _revision(DateTime value) => value
    .toIso8601String()
    .replaceAll(RegExp(r'[-:]'), '')
    .replaceAll(RegExp(r'\.\d+Z$'), 'Z');
String _date(DateTime value) => value.toIso8601String().substring(0, 10);
int _int(Object? value) => value is int ? value : int.tryParse('$value') ?? 0;
double _double(Object? value) =>
    value is num ? value.toDouble() : double.tryParse('$value') ?? 0;
int? _positiveInt(Object? value) {
  final parsed = _int(value);
  return parsed > 0 ? parsed : null;
}

Set<int> _intSet(Object? value) => value is List
    ? value.map(_int).where((number) => number > 0).toSet()
    : const {};
