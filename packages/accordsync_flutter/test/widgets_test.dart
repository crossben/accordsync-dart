import 'dart:async';

import 'package:accordsync_flutter/accordsync_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

final schema = defineSchema({
  'dossier': {'name': lww(), 'status': conflict(), 'visits': counter()},
});

/// A server that accepts every push and hands back whatever [incoming] holds.
final class _Server implements Transport {
  final List<Map<String, Object?>> incoming = [];
  int pulls = 0;
  int pushes = 0;
  var _cursor = 0;

  @override
  Future<PushResult> push(String deviceId, List<Map<String, Object?>> ops) async {
    pushes++;
    return PushResult(acked: [for (final o in ops) o['op_id']! as String], refused: const []);
  }

  @override
  Future<PullResult> pull(String deviceId, int cursor, int limit) async {
    pulls++;
    final items = [for (final o in incoming) OpItem(o)];
    incoming.clear();
    _cursor += items.length;
    return PullPage(items: items, cursor: _cursor, hasMore: false);
  }
}

Future<AccordClient> open(Transport t, [String id = 'me']) =>
    AccordClient.open(schema: schema, storage: MemoryStorage(), transport: t, deviceId: id);

Widget app(AccordClient c, Widget child) => Directionality(
  textDirection: TextDirection.ltr,
  child: AccordProvider(client: c, child: child),
);

void main() {
  testWidgets('RecordBuilder rebuilds on local writes and on synced changes', (tester) async {
    final server = _Server();
    final c = await tester.runAsync(() => open(server));
    var builds = 0;
    await tester.pumpWidget(
      app(
        c!,
        RecordBuilder(
          record: 'dossier:1',
          builder: (_, f) {
            builds++;
            return Text(f == null ? 'none' : '${f['name'] ?? '-'} ${f['visits']}');
          },
        ),
      ),
    );
    expect(find.text('none'), findsOneWidget);

    await tester.runAsync(() => c.assign('dossier:1', 'name', 'Awa'));
    await tester.pump();
    expect(find.text('Awa 0'), findsOneWidget);

    // Someone else's increment arrives with a sync.
    final other = await tester.runAsync(() => open(_Server(), 'other'));
    final op = await tester.runAsync(() => other!.inc('dossier:1', 'visits', 3));
    server.incoming.add(encodeOp(op!));
    await tester.runAsync(c.sync);
    await tester.pump();
    expect(find.text('Awa 3'), findsOneWidget);

    // A change to another record does not rebuild this one.
    final before = builds;
    await tester.runAsync(() => c.assign('dossier:2', 'name', 'x'));
    await tester.pump();
    expect(builds, before);
  });

  testWidgets('ConflictsBuilder shows the values, and clears after a resolution', (tester) async {
    final server = _Server();
    final c = await tester.runAsync(() => open(server));
    final other = await tester.runAsync(() => open(_Server(), 'other'));
    await tester.pumpWidget(
      app(
        c!,
        ConflictsBuilder(
          builder: (_, cs) => Text(
            cs.isEmpty ? 'ok' : cs.map((x) => x.values.map((v) => v.value).join('|')).join(),
          ),
        ),
      ),
    );
    expect(find.text('ok'), findsOneWidget);
    await tester.runAsync(() => c.assign('dossier:1', 'status', 'approved'));
    final theirs = await tester.runAsync(() => other!.assign('dossier:1', 'status', 'rejected'));
    server.incoming.add(encodeOp(theirs!));
    await tester.runAsync(c.sync);
    await tester.pump();
    expect(find.text('approved|rejected'), findsOneWidget);

    await tester.runAsync(() => c.resolve('dossier:1', 'status', 'approved'));
    await tester.pump();
    expect(find.text('ok'), findsOneWidget);
  });

  testWidgets('SyncStatusBuilder follows pending writes', (tester) async {
    final c = await tester.runAsync(() => open(_Server()));
    await tester.pumpWidget(
      app(c!, SyncStatusBuilder(builder: (_, s) => Text('pending ${s.pending}'))),
    );
    await tester.runAsync(() => c.inc('dossier:1', 'visits', 1));
    await tester.pump();
    expect(find.text('pending 1'), findsOneWidget);
    await tester.runAsync(c.sync);
    await tester.pump();
    expect(find.text('pending 0'), findsOneWidget);
  });

  testWidgets('AccordLifecycle starts sync, and syncs again when the network comes back', (
    tester,
  ) async {
    final server = _Server();
    // Opened in the test's fake zone, like the widget's timers (no real I/O anywhere here).
    final opening = open(server);
    await tester.pump(); // runs the open's microtasks
    final c = await opening;
    final online = StreamController<bool>();

    // Widget timers and listeners run in the test's fake zone; nothing here does real I/O, so
    // pumping is enough to run them.
    Future<void> settle() async {
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
    }

    await tester.pumpWidget(
      app(c, AccordLifecycle(client: c, online: online.stream, child: const SizedBox())),
    );
    await settle();
    expect(server.pulls, 1, reason: 'start() syncs once at once');

    online.add(false);
    await settle();
    expect(server.pulls, 1, reason: 'going offline does not sync');

    online.add(true);
    await settle();
    expect(server.pulls, 2, reason: 'the network came back');

    // In the background, no sync even after the 30 s interval; back in the foreground, at once.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump(const Duration(seconds: 31));
    await settle();
    expect(server.pulls, 2, reason: 'paused in the background');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settle();
    expect(server.pulls, 3, reason: 'resumed');

    await tester.pumpWidget(const SizedBox()); // disposes: background sync stops
    unawaited(online.close()); // the widget already cancelled its subscription
  });
}
