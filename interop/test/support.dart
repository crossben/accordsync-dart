import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:accordsync/accordsync.dart';
import 'package:http/http.dart' as http;

/// The server under test (`node/server.mjs`), and its test-only routes.
final serverUrl = Platform.environment['ACCORD_URL'] ?? 'http://localhost:8787';
final testUrl = Platform.environment['ACCORD_TEST_URL'] ?? 'http://localhost:8788';

/// The same schema as `node/schema.mjs`.
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

Future<Map<String, Object?>> _testRoute(String path) async {
  final res = await http.get(Uri.parse('$testUrl$path'));
  if (res.statusCode != 200) throw StateError('$path → ${res.statusCode} ${res.body}');
  return jsonDecode(res.body) as Map<String, Object?>;
}

/// Fails with instructions when the server is not running.
Future<void> requireServer() async {
  try {
    await http.get(Uri.parse('$serverUrl/health'));
  } on Object {
    throw StateError('No Accord server at $serverUrl. Start it with interop/run.sh (see README).');
  }
}

Future<void> resetServer() => _testRoute('/reset');

Future<Map<String, Object?>> compactServer() => _testRoute('/compact');

/// A JWT for [sub] with read and write access to [zones].
Future<String> tokenFor(String sub, List<String> zones) async =>
    (await _testRoute('/token?sub=$sub${zones.map((z) => '&zone=$z').join()}'))['token']! as String;

/// A network that loses requests, and loses responses after the server applied the request.
final class FlakyClient extends http.BaseClient {
  FlakyClient(this.random, this.loss);
  final Random random;
  double loss;
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (random.nextDouble() < loss / 2) throw const SocketException('network down (request lost)');
    final res = await http.Response.fromStream(await _inner.send(request));
    if (random.nextDouble() < loss / 2) throw const SocketException('network down (response lost)');
    return http.StreamedResponse(
      Stream.value(res.bodyBytes),
      res.statusCode,
      headers: res.headers,
      request: request,
    );
  }
}

/// The canonical state of every record a device holds, like the TypeScript side computes it.
String snapshotOf(AccordClient c) => canonicalJson({for (final r in c.records()) r: c.read(r)});

/// A TypeScript device (`node/ts-client.mjs`), driven over stdin/stdout.
final class TsDevice {
  TsDevice._(this._process) {
    _process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) => _answers.removeAt(0).complete(jsonDecode(line) as Map<String, Object?>));
    _process.stderr.transform(utf8.decoder).listen(stderr.write);
  }

  static Future<TsDevice> open({
    required String deviceId,
    required String token,
    int seed = 1,
    double loss = 0,
  }) async {
    final process = await Process.start('node', [
      'ts-client.mjs',
    ], workingDirectory: '${_interopDir()}/node');
    final d = TsDevice._(process);
    await d.call({
      'cmd': 'open',
      'deviceId': deviceId,
      'token': token,
      'url': serverUrl,
      'seed': seed,
      'loss': loss,
    });
    return d;
  }

  final Process _process;
  final List<Completer<Map<String, Object?>>> _answers = [];

  Future<Map<String, Object?>> call(Map<String, Object?> command) {
    final c = Completer<Map<String, Object?>>();
    _answers.add(c);
    _process.stdin.writeln(jsonEncode(command));
    return c.future.then((a) {
      if (a['ok'] != true && command['cmd'] != 'sync') throw StateError('ts: ${a['error']}');
      return a;
    });
  }

  Future<String> snapshot() async => (await call({'cmd': 'snapshot'}))['snapshot']! as String;

  Future<void> close() async {
    await call({'cmd': 'close'});
    await _process.exitCode;
  }
}

String _interopDir() {
  var dir = Directory.current;
  while (!File('${dir.path}/node/ts-client.mjs').existsSync()) {
    if (Directory('${dir.path}/interop').existsSync()) return '${dir.path}/interop';
    final parent = dir.parent;
    if (parent.path == dir.path) throw StateError('interop/ not found');
    dir = parent;
  }
  return dir.path;
}
