import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:jive/data/playback/hls_parser.dart';
import 'package:jive/data/playback/local_proxy.dart';
import 'package:jive/domain/playback_source.dart';
import 'package:video_player/video_player.dart';

void main() => runApp(const MaterialApp(home: PlaybackProbe()));

/// Small, source independent entry point for the first OpenHarmony playback gate.
class PlaybackProbe extends StatefulWidget {
  const PlaybackProbe({super.key});

  @override
  State<PlaybackProbe> createState() => _PlaybackProbeState();
}

class _PlaybackProbeState extends State<PlaybackProbe> {
  static const _mp4Sample =
      'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4';
  static const _hlsSample =
      'https://test-streams.mux.dev/x36xhzz/url_2/193039199_mp4_h264_aac_ld_7.m3u8';

  final _url = TextEditingController(text: _mp4Sample);
  final _client = http.Client();
  final _proxy = LocalProxyServer();
  VideoPlayerController? _player;
  String _result = '等待测试';
  String _mode = '';
  bool _busy = false;
  bool _landscape = false;

  @override
  void dispose() {
    _url.dispose();
    _client.close();
    unawaited(_player?.dispose());
    unawaited(_proxy.close());
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  Future<void> _load({required bool hls, required bool proxy}) async {
    if (_busy) return;
    final uri = Uri.tryParse(_url.text.trim());
    if (uri == null || !uri.hasScheme) {
      setState(() => _result = '请输入完整的视频 URL');
      return;
    }
    setState(() {
      _busy = true;
      _result = '初始化中…';
      _mode = proxy ? '本地代理 HLS' : (hls ? '直连 HLS' : '直连 MP4');
    });
    VideoPlayerController? next;
    try {
      await _player?.dispose();
      _player = null;
      await _proxy.close();
      var playbackUri = uri;
      if (proxy) {
        final parser = HlsParser(client: _client);
        final decision = await parser.resolve(
          PlaybackSource(url: uri, format: PlaybackFormat.hls),
        );
        if (!decision.isCacheable) {
          throw StateError('清单无法进入代理：${decision.reason}');
        }
        const token = 'phase1';
        final plan = parser.buildProxyPlan(decision.mediaPlaylist!, token);
        await _proxy.start();
        _proxy.register(
          ProxySessionRoute(
            token: token,
            proxyManifest: plan.proxyManifest,
            resources: plan.resources,
            extByResourceId: plan.extByResourceId,
            sessionHeaders: const {},
            client: _client,
          ),
        );
        playbackUri = Uri.parse(_proxy.baseUrl(token));
      }
      next = VideoPlayerController.networkUrl(
        playbackUri,
        formatHint: hls ? VideoFormat.hls : null,
      );
      await next.initialize().timeout(const Duration(seconds: 25));
      next.addListener(_onPlayerChanged);
      await next.play();
      if (!mounted) return;
      setState(() {
        _player = next;
        _result = '已初始化并开始播放：$playbackUri';
      });
    } catch (error) {
      await next?.dispose();
      if (mounted) setState(() => _result = '失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _onPlayerChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _toggleFullscreen() async {
    _landscape = !_landscape;
    await SystemChrome.setPreferredOrientations(
      _landscape
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [DeviceOrientation.portraitUp],
    );
    await SystemChrome.setEnabledSystemUIMode(
      _landscape ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final value = player?.value;
    final duration = value?.duration ?? Duration.zero;
    final position = value?.position ?? Duration.zero;
    return Scaffold(
      appBar: AppBar(title: const Text('Jive 鸿蒙播放验证')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _url,
            decoration: const InputDecoration(labelText: '视频 URL'),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => _url.text = _mp4Sample,
                child: const Text('示例 MP4'),
              ),
              TextButton(
                onPressed: () => _url.text = _hlsSample,
                child: const Text('示例 HLS'),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: _busy ? null : () => _load(hls: false, proxy: false),
                child: const Text('直连 MP4'),
              ),
              FilledButton(
                onPressed: _busy ? null : () => _load(hls: true, proxy: false),
                child: const Text('直连 HLS'),
              ),
              FilledButton(
                onPressed: _busy ? null : () => _load(hls: true, proxy: true),
                child: const Text('本地代理 HLS'),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text('模式：$_mode'),
          SelectableText(_result),
          const SizedBox(height: 12),
          if (value?.isInitialized == true) ...[
            AspectRatio(
              aspectRatio: value!.aspectRatio,
              child: VideoPlayer(player!),
            ),
            Slider(
              value: position.inMilliseconds
                  .clamp(0, duration.inMilliseconds)
                  .toDouble(),
              max: duration.inMilliseconds.toDouble().clamp(1, double.infinity),
              onChanged: (milliseconds) =>
                  player.seekTo(Duration(milliseconds: milliseconds.round())),
            ),
            Text('${position.inSeconds}s / ${duration.inSeconds}s'),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: () =>
                      value.isPlaying ? player.pause() : player.play(),
                  child: Text(value.isPlaying ? '暂停' : '播放'),
                ),
                FilledButton(
                  onPressed: _toggleFullscreen,
                  child: Text(_landscape ? '退出全屏' : '全屏'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
