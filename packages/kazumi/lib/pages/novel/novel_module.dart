import 'package:flutter_modular/flutter_modular.dart';
import 'package:kazumi/pages/novel/novel_search_page.dart';

/// 轻小说 tab 的路由模块。
///
/// 放在 /tab/novel 下，和 popular/timeline/collect/my 平级 —— 这样它就是一个
/// 真正的底部 tab，而不是一个从设置里点进去的二级页面。
final novelModule = createModule(
  path: '/novel',
  register: (c) {
    c.route(
      '/',
      transition: TransitionType.none,
      child: (context, state) => const NovelSearchPage(),
    );
  },
);
