import 'package:flutter/material.dart';

import '../../shared/source_selector.dart';

/// Settings opens directly in management mode; the sheet starts in selection.
class SourceManagementPage extends StatelessWidget {
  const SourceManagementPage({super.key});

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: SafeArea(child: SourcePanel(isPage: true)));
}
