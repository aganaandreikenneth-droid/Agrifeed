import 'package:flutter/widgets.dart';

import '../../services/feeder_live.dart';
import '../../services/feeder_selection.dart';

/// The selected feeder for everything below it: its ID, the user's role and
/// permissions, and whether the database connection is up.
///
/// Feeder screens read the feeder ID from here, never from a constant.
/// Permission checks here only shape the UI; the Security Rules enforce them.
class FeederScope extends InheritedWidget {
  const FeederScope({
    super.key,
    required this.feeder,
    required this.online,
    required this.controls,
    required super.child,
  });

  final FeederSummary feeder;
  final bool online;

  /// Live data and requests for this feeder, as the signed-in user.
  final FeederControls controls;

  static FeederScope of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<FeederScope>()!;

  @override
  bool updateShouldNotify(FeederScope oldWidget) =>
      feeder != oldWidget.feeder ||
      online != oldWidget.online ||
      controls != oldWidget.controls;
}
