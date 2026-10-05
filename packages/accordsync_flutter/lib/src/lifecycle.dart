import 'dart:async';

import 'package:accordsync/accordsync.dart';
import 'package:flutter/widgets.dart';

/// Syncs while the app is in the foreground, pauses in the background, and syncs at once when the
/// network comes back.
///
/// Accord has no connectivity dependency: pass [online] from the package you already use, for
/// example with `connectivity_plus`:
///
/// ```dart
/// AccordLifecycle(
///   client: accord,
///   online: Connectivity().onConnectivityChanged
///       .map((r) => !r.contains(ConnectivityResult.none)),
///   child: const MyApp(),
/// )
/// ```
///
/// Writes never wait for any of this: they complete as soon as they are saved on the device.
class AccordLifecycle extends StatefulWidget {
  const AccordLifecycle({super.key, required this.client, this.online, required this.child});

  final AccordClient client;

  /// Network reachability: each `true` triggers a sync.
  final Stream<bool>? online;
  final Widget child;

  @override
  State<AccordLifecycle> createState() => _AccordLifecycleState();
}

class _AccordLifecycleState extends State<AccordLifecycle> {
  late final AppLifecycleListener _app;
  StreamSubscription<bool>? _net;

  @override
  void initState() {
    super.initState();
    widget.client.start(); // after writes, every syncInterval, with backoff while offline
    _app = AppLifecycleListener(
      onResume: widget.client.start,
      // The OS suspends the app anyway; stop timers cleanly.
      onHide: widget.client.stop,
    );
    _listen();
  }

  @override
  void didUpdateWidget(AccordLifecycle old) {
    super.didUpdateWidget(old);
    if (old.online != widget.online || old.client != widget.client) {
      if (old.client != widget.client) {
        old.client.stop();
        widget.client.start();
      }
      _listen();
    }
  }

  void _listen() {
    unawaited(_net?.cancel());
    _net = widget.online?.listen((up) {
      if (up) unawaited(widget.client.sync().catchError((Object _) {}));
    });
  }

  @override
  void dispose() {
    _app.dispose();
    unawaited(_net?.cancel());
    widget.client.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
