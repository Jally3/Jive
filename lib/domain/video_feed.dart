enum VideoFeed { updated, popular, newReleases, topRated }

extension VideoFeedLabel on VideoFeed {
  String get label => switch (this) {
    VideoFeed.updated => '更新',
    VideoFeed.popular => '热门',
    VideoFeed.newReleases => '新片',
    VideoFeed.topRated => '高分',
  };
}
