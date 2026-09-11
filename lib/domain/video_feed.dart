enum VideoFeed { updated, popular, newReleases, topRated }

extension VideoFeedLabel on VideoFeed {
  String get label => switch (this) {
    VideoFeed.updated => '默认',
    VideoFeed.popular => '最热',
    VideoFeed.newReleases => '最新',
    VideoFeed.topRated => '高分',
  };
}
