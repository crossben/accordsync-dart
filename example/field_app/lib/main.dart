// Accord demo: two field agents, one dossier. Each phone pane is a separate device with its own
// database and its own network switch. Turn a phone offline, edit on both, bring it back: every
// field merges by its rule, and two different decisions are kept for someone to settle.
//
// Needs the Accord server from interop/ (see README): from the Android emulator it is at 10.0.2.2.
import 'dart:async';
import 'dart:convert';

import 'package:accordsync_flutter/accordsync_flutter.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

const serverUrl = String.fromEnvironment(
  'ACCORD_URL',
  defaultValue: 'http://10.0.2.2:8787',
);
const tokenUrl = String.fromEnvironment(
  'ACCORD_TOKEN_URL',
  defaultValue: 'http://10.0.2.2:8788',
);
const dossier = 'dossier:1';

/// The schema the server declares (interop/node/schema.mjs).
final schema = defineSchema({
  'dossier': {
    'agent': lww(),
    'zone': lww(),
    'client_name': lww(),
    'status': conflict(),
    'visits': counter(),
    'docs': set(),
  },
});

void main() => runApp(const FieldApp());

class FieldApp extends StatelessWidget {
  const FieldApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Accord field',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorSchemeSeed: const Color(0xFF0F766E),
      useMaterial3: true,
    ),
    darkTheme: ThemeData(
      colorSchemeSeed: const Color(0xFF0F766E),
      brightness: Brightness.dark,
      useMaterial3: true,
    ),
    home: const Agents(),
  );
}

/// A transport with a switch: off is airplane mode.
final class SwitchableTransport implements Transport {
  SwitchableTransport(this.inner);
  final Transport inner;
  final online = ValueNotifier(true);

  void _check() {
    if (!online.value) throw const HttpError(0, 'offline');
  }

  @override
  Future<PushResult> push(String deviceId, List<Map<String, Object?>> ops) {
    _check();
    return inner.push(deviceId, ops);
  }

  @override
  Future<PullResult> pull(String deviceId, int cursor, int limit) {
    _check();
    return inner.pull(deviceId, cursor, limit);
  }
}

final class Agent {
  Agent(this.name, this.client, this.network);
  final String name;
  final AccordClient client;
  final SwitchableTransport network;

  static Future<Agent> open(String name) async {
    final res = await http.get(
      Uri.parse('$tokenUrl/token?sub=$name&zone=dakar'),
    );
    final token =
        (jsonDecode(res.body) as Map<String, Object?>)['token']! as String;
    final network = SwitchableTransport(
      HttpTransport(url: serverUrl, getToken: () => token),
    );
    final client = await AccordClient.open(
      schema: schema,
      storage: DriftStorage(
        AccordDatabase(driftDatabase(name: 'accord-$name')),
        closeDatabase: true,
      ),
      transport: network,
      syncInterval: const Duration(seconds: 5),
    );
    return Agent(name, client, network);
  }
}

class Agents extends StatefulWidget {
  const Agents({super.key});

  @override
  State<Agents> createState() => _AgentsState();
}

class _AgentsState extends State<Agents> {
  late final Future<List<Agent>> _agents = _open();

  Future<List<Agent>> _open() async {
    final agents = [await Agent.open('awa'), await Agent.open('moussa')];
    final awa = agents.first.client;
    await awa.sync();
    if (awa.read(dossier) == null) {
      await awa.assign(dossier, 'zone', 'dakar');
      await awa.assign(dossier, 'client_name', 'Aminata Fall');
      await awa.sync();
    }
    return agents;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Accord · two agents, one dossier')),
    body: FutureBuilder(
      future: _agents,
      builder: (context, snap) {
        if (snap.hasError) {
          return Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Cannot reach the Accord server at $serverUrl.\n\nStart it with interop/run.sh '
              'or node interop/node/server.mjs (see the example README).\n\n${snap.error}',
            ),
          );
        }
        final agents = snap.data;
        if (agents == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          padding: const EdgeInsets.all(12),
          children: [
            for (final a in agents)
              AccordProvider(
                client: a.client,
                child: AccordLifecycle(
                  client: a.client,
                  online: _changes(a.network.online),
                  child: Phone(agent: a),
                ),
              ),
          ],
        );
      },
    ),
  );
}

Stream<bool> _changes(ValueNotifier<bool> n) {
  late final StreamController<bool> c;
  void push() => c.add(n.value);
  c = StreamController<bool>(
    onListen: () => n.addListener(push),
    onCancel: () => n.removeListener(push),
  );
  return c.stream;
}

/// One agent's phone: network switch, sync status, and the dossier.
class Phone extends StatelessWidget {
  const Phone({super.key, required this.agent});
  final Agent agent;

  @override
  Widget build(BuildContext context) {
    final client = agent.client;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(child: Text(agent.name[0].toUpperCase())),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    agent.name == 'awa' ? 'Awa' : 'Moussa',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                ValueListenableBuilder(
                  valueListenable: agent.network.online,
                  builder: (_, on, _) => Row(
                    children: [
                      Icon(
                        on ? Icons.wifi : Icons.airplanemode_active,
                        size: 18,
                      ),
                      Switch(
                        value: on,
                        onChanged: (v) => agent.network.online.value = v,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            SyncStatusBuilder(
              builder: (_, s) => Text(
                s.pending == 0
                    ? 'Everything synced'
                    : '${s.pending} change(s) waiting to sync',
                style: TextStyle(
                  color: s.pending == 0 ? scheme.primary : scheme.tertiary,
                ),
              ),
            ),
            const Divider(height: 24),
            RecordBuilder(
              record: dossier,
              builder: (context, f) {
                if (f == null) return const Text('Waiting for the dossier…');
                final docs = (f['docs']! as List<Object?>).cast<String>();
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Label('Client · lww()'),
                    _NameField(
                      value: f['client_name'] as String? ?? '',
                      onSubmit: (v) => client.assign(dossier, 'client_name', v),
                    ),
                    const SizedBox(height: 12),
                    _Label('Visits · counter()'),
                    Row(
                      children: [
                        IconButton.outlined(
                          onPressed: () => client.inc(dossier, 'visits', -1),
                          icon: const Icon(Icons.remove),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Text(
                            '${f['visits']}',
                            style: Theme.of(context).textTheme.headlineSmall,
                          ),
                        ),
                        IconButton.filledTonal(
                          onPressed: () => client.inc(dossier, 'visits', 1),
                          icon: const Icon(Icons.add),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _Label('Documents · set()'),
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final d in ['ID card', 'Receipt', 'Photo'])
                          FilterChip(
                            label: Text(d),
                            selected: docs.contains(d),
                            onSelected: (on) => on
                                ? client.add(dossier, 'docs', d)
                                : client.remove(dossier, 'docs', d),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    _Label('Decision · conflict()'),
                    _Decision(status: f['status'], client: client),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Text(text, style: Theme.of(context).textTheme.labelMedium),
  );
}

class _NameField extends StatefulWidget {
  const _NameField({required this.value, required this.onSubmit});
  final String value;
  final void Function(String) onSubmit;
  @override
  State<_NameField> createState() => _NameFieldState();
}

class _NameFieldState extends State<_NameField> {
  late final _c = TextEditingController(text: widget.value);
  final _focus = FocusNode();

  @override
  void didUpdateWidget(_NameField old) {
    super.didUpdateWidget(old);
    // Show merged values, but never overwrite what the agent is typing.
    if (!_focus.hasFocus && _c.text != widget.value) _c.text = widget.value;
  }

  @override
  void dispose() {
    _c.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TextField(
    controller: _c,
    focusNode: _focus,
    decoration: const InputDecoration(
      isDense: true,
      border: OutlineInputBorder(),
    ),
    textInputAction: TextInputAction.done,
    onSubmitted: widget.onSubmit,
  );
}

/// The decision: approve or reject; when two agents decided differently, both are shown and
/// someone keeps one. Accord never picks.
class _Decision extends StatelessWidget {
  const _Decision({required this.status, required this.client});
  final Object? status;
  final AccordClient client;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final s = status as Map<String, Object?>?;
    final conflicted = s?['conflicted'] as List<Object?>?;
    if (conflicted != null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Two decisions were made offline. Keep one:',
              style: TextStyle(color: scheme.onErrorContainer),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                for (final v in conflicted.cast<Map<String, Object?>>())
                  FilledButton.tonal(
                    onPressed: () =>
                        client.resolve(dossier, 'status', v['value']),
                    child: Text('Keep "${v['value']}"'),
                  ),
              ],
            ),
          ],
        ),
      );
    }
    final current = s?['value'] as String?;
    return SegmentedButton<String>(
      emptySelectionAllowed: true,
      segments: const [
        ButtonSegment(
          value: 'approved',
          label: Text('Approve'),
          icon: Icon(Icons.check),
        ),
        ButtonSegment(
          value: 'rejected',
          label: Text('Reject'),
          icon: Icon(Icons.close),
        ),
      ],
      selected: {?current},
      onSelectionChanged: (sel) {
        if (sel.isNotEmpty) client.assign(dossier, 'status', sel.first);
      },
    );
  }
}
