import 'dart:async';

import 'package:accordsync/accordsync.dart';
import 'package:flutter/widgets.dart';

/// Makes an [AccordClient] available to the widgets below it.
///
/// ```dart
/// AccordProvider(client: accord, child: const MyApp())
/// ```
class AccordProvider extends InheritedWidget {
  const AccordProvider({super.key, required this.client, required super.child});

  final AccordClient client;

  /// The nearest client above [context].
  static AccordClient of(BuildContext context) {
    final p = context.dependOnInheritedWidgetOfExactType<AccordProvider>();
    assert(p != null, 'No AccordProvider above this widget');
    return p!.client;
  }

  @override
  bool updateShouldNotify(AccordProvider oldWidget) => oldWidget.client != client;
}

/// Base for widgets that rebuild when the client reports something.
abstract class _AccordState<W extends StatefulWidget> extends State<W> {
  AccordClient? _client;
  final List<StreamSubscription<Object?>> _subs = [];

  /// The streams to listen to, and whether an event concerns this widget.
  List<StreamSubscription<Object?>> listen(AccordClient client, void Function() rebuild);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final client = AccordProvider.of(context);
    if (client == _client) return;
    _cancel();
    _client = client;
    _subs.addAll(
      listen(client, () {
        if (mounted) setState(() {});
      }),
    );
  }

  void _cancel() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
  }

  @override
  void dispose() {
    _cancel();
    super.dispose();
  }
}

/// Builds from one record's fields, and rebuilds whenever that record changes on this device (a
/// local write, a sync, a rollback, the record leaving scope). `fields` is null when the device
/// has never seen the record; fields with no value are absent.
class RecordBuilder extends StatefulWidget {
  const RecordBuilder({super.key, required this.record, required this.builder});

  final String record;
  final Widget Function(BuildContext context, Map<String, Object?>? fields) builder;

  @override
  State<RecordBuilder> createState() => _RecordBuilderState();
}

class _RecordBuilderState extends _AccordState<RecordBuilder> {
  @override
  List<StreamSubscription<Object?>> listen(AccordClient client, void Function() rebuild) => [
    client.changes.listen((records) {
      if (records.contains(widget.record)) rebuild();
    }),
  ];

  @override
  Widget build(BuildContext context) => widget.builder(context, _client!.read(widget.record));
}

/// Builds from every `conflict()` field holding more than one value, so the app can show the values
/// and let someone decide (`client.resolve`).
class ConflictsBuilder extends StatefulWidget {
  const ConflictsBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, List<ConflictInfo> conflicts) builder;

  @override
  State<ConflictsBuilder> createState() => _ConflictsBuilderState();
}

class _ConflictsBuilderState extends _AccordState<ConflictsBuilder> {
  @override
  List<StreamSubscription<Object?>> listen(AccordClient client, void Function() rebuild) => [
    client.changes.listen((_) => rebuild()),
  ];

  @override
  Widget build(BuildContext context) => widget.builder(context, _client!.conflicts());
}

/// Builds from the sync status: pending writes, last sync, last error.
class SyncStatusBuilder extends StatefulWidget {
  const SyncStatusBuilder({super.key, required this.builder});

  final Widget Function(BuildContext context, SyncStatus status) builder;

  @override
  State<SyncStatusBuilder> createState() => _SyncStatusBuilderState();
}

class _SyncStatusBuilderState extends _AccordState<SyncStatusBuilder> {
  @override
  List<StreamSubscription<Object?>> listen(AccordClient client, void Function() rebuild) => [
    client.changes.listen((_) => rebuild()),
    client.synced.listen((_) => rebuild()),
    client.errors.listen((_) => rebuild()),
    client.refusals.listen((_) => rebuild()),
  ];

  @override
  Widget build(BuildContext context) => widget.builder(context, _client!.status());
}
