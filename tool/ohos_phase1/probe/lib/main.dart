import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';

void main() => runApp(const MaterialApp(home: PlayerProbe()));

class PlayerProbe extends StatefulWidget {
  const PlayerProbe({super.key});

  @override
  State<PlayerProbe> createState() => _PlayerProbeState();
}

class _PlayerProbeState extends State<PlayerProbe> {
  static const mp4Sample =
      'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4';
  static const hlsSample =
      'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8';

  final url = TextEditingController(text: mp4Sample);
  VideoPlayerController? player;
  String status = '等待测试';
  bool landscape = false;

  @override
  void dispose() {
    url.dispose();
    unawaited(player?.dispose());
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    super.dispose();
  }

  Future<void> load(bool hls) async {
    final source = Uri.tryParse(url.text.trim());
    if (source == null || !source.scheme.startsWith('http')) {
      setState(() => status = '请输入 HTTP(S) 视频 URL');
      return;
    }
    setState(() => status = '初始化中…');
    final old = player;
    player = null;
    await old?.dispose();
    final next = VideoPlayerController.networkUrl(
      source,
      formatHint: hls ? VideoFormat.hls : null,
    );
    try {
      await next.initialize().timeout(const Duration(seconds: 25));
      next.addListener(refresh);
      await next.play();
      if (!mounted) return;
      setState(() {
        player = next;
        status = '开始播放：$source';
      });
    } catch (error) {
      await next.dispose();
      if (mounted) setState(() => status = '失败：$error');
    }
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  Future<void> toggleFullscreen() async {
    landscape = !landscape;
    await SystemChrome.setPreferredOrientations(
      landscape
          ? [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]
          : [DeviceOrientation.portraitUp],
    );
    await SystemChrome.setEnabledSystemUIMode(
      landscape ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final current = player;
    final value = current?.value;
    final duration = value?.duration ?? Duration.zero;
    final position = value?.position ?? Duration.zero;
    return Scaffold(
      appBar: AppBar(title: const Text('OpenHarmony video_player 验证')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: url,
            decoration: const InputDecoration(labelText: '视频 URL'),
          ),
          Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: () => url.text = mp4Sample,
                child: const Text('示例 MP4'),
              ),
              TextButton(
                onPressed: () => url.text = hlsSample,
                child: const Text('示例 HLS'),
              ),
              FilledButton(
                onPressed: () => load(false),
                child: const Text('播放 MP4'),
              ),
              FilledButton(
                onPressed: () => load(true),
                child: const Text('播放 HLS'),
              ),
            ],
          ),
          SelectableText(status),
          const SizedBox(height: 12),
          if (value?.isInitialized == true) ...[
            AspectRatio(
              aspectRatio: value!.aspectRatio,
              child: VideoPlayer(current!),
            ),
            Slider(
              value: position.inMilliseconds
                  .clamp(0, duration.inMilliseconds)
                  .toDouble(),
              max: duration.inMilliseconds.toDouble().clamp(1, double.infinity),
              onChanged: (milliseconds) =>
                  current.seekTo(Duration(milliseconds: milliseconds.round())),
            ),
            Text('${position.inSeconds}s / ${duration.inSeconds}s'),
            Wrap(
              spacing: 8,
              children: [
                FilledButton(
                  onPressed: () =>
                      value.isPlaying ? current.pause() : current.play(),
                  child: Text(value.isPlaying ? '暂停' : '播放'),
                ),
                FilledButton(
                  onPressed: toggleFullscreen,
                  child: Text(landscape ? '退出全屏' : '全屏'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
