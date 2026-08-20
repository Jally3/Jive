import '../domain/video.dart';

/// 敏感分类关键词黑名单：按分类名子串匹配，覆盖「伦理片」「午夜剧场」
/// 「福利视频」等变体。新增关键词时注意与正常分类名没有子串关系
/// （如「伦理」与「理论」字符不同，不会误伤）。
const blockedCategoryKeywords = [
  '伦理',
  '擦边',
  '福利',
  '午夜',
  '写真',
  '成人',
  '情趣',
  '诱惑',
  '制服',
];

/// 分类名是否命中黑名单。
bool isBlockedCategoryName(String name) {
  if (name.isEmpty) return false;
  for (final keyword in blockedCategoryKeywords) {
    if (name.contains(keyword)) return true;
  }
  return false;
}

/// 视频是否属于敏感分类（按条目的分类名判断）。
bool isBlockedVideo(Video video) => isBlockedCategoryName(video.category);
