enum VideoFeed { updated, recommended, popular, newReleases, topRated }

extension VideoFeedLabel on VideoFeed {
  String get label => switch (this) {
    VideoFeed.updated => '综合',
    VideoFeed.recommended => '猜你喜欢',
    VideoFeed.popular => '热门',
    VideoFeed.newReleases => '新片',
    VideoFeed.topRated => '高分',
  };
}
