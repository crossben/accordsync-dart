import 'dart:async';
import 'dart:convert';

import 'package:accordsync_core/accordsync_core.dart';
import 'package:http/http.dart' as http;

/// The server's answer to a push.
final class PushResult {
  const PushResult({required this.acked, required this.refused});

  factory PushResult.fromJson(Map<String, Object?> json) => PushResult(
    acked: (json['acked']! as List<Object?>).cast<String>(),
    refused: [
      for (final r in (json['refused']! as List<Object?>).cast<Map<String, Object?>>())
        (opId: r['op_id']! as String, reason: r['reason']! as String),
    ],
  );

  final List<OpId> acked;
  final List<({OpId opId, String reason})> refused;
}

/// One item of a pull page.
sealed class PullItem {
  const PullItem();

  factory PullItem.fromJson(Map<String, Object?> json) => switch (json['type']) {
    'op' => OpItem(json['op']! as Map<String, Object?>),
    'snapshot' => SnapshotItem(RecordSnapshot.fromJson(json['snapshot']! as Map<String, Object?>)),
    'exit' => ExitItem(json['record']! as String),
    final t => throw FormatException('unknown pull item type $t'),
  };
}

/// An op, in the wire format.
final class OpItem extends PullItem {
  const OpItem(this.op);
  final Map<String, Object?> op;
}

/// A compacted record (ADR-0008).
final class SnapshotItem extends PullItem {
  const SnapshotItem(this.snapshot);
  final RecordSnapshot snapshot;
}

/// The record left this device's read scope (ADR-0004).
final class ExitItem extends PullItem {
  const ExitItem(this.record);
  final String record;
}

sealed class PullResult {
  const PullResult();

  factory PullResult.fromJson(Map<String, Object?> json) => json['resync_required'] == true
      ? const ResyncRequired()
      : PullPage(
          items: [
            for (final i in (json['items']! as List<Object?>).cast<Map<String, Object?>>())
              PullItem.fromJson(i),
          ],
          cursor: (json['cursor']! as num).toInt(),
          hasMore: json['has_more']! as bool,
          deviceSeq: (json['device_seq'] as num?)?.toInt(),
        );
}

final class PullPage extends PullResult {
  const PullPage({
    required this.items,
    required this.cursor,
    required this.hasMore,
    this.deviceSeq,
  });
  final List<PullItem> items;
  final int cursor;
  final bool hasMore;

  /// The highest op number the server has applied from this device.
  final int? deviceSeq;
}

/// The server asks the device to drop its data and pull from zero.
final class ResyncRequired extends PullResult {
  const ResyncRequired();
}

/// How a client reaches the server. [HttpTransport] is the real one; tests can fake it.
abstract interface class Transport {
  Future<PushResult> push(String deviceId, List<Map<String, Object?>> ops);
  Future<PullResult> pull(String deviceId, int cursor, int limit);
}

final class HttpError implements Exception {
  const HttpError(this.status, this.message);
  final int status;
  final String message;
  @override
  String toString() => 'HttpError: $message';
}

/// Talks to an Accord server over HTTPS (see the server's docs/protocol.md).
final class HttpTransport implements Transport {
  /// [url] is the server's base URL, e.g. `https://sync.example.com`. [getToken] returns the
  /// current JWT from your app's auth; it is called before every request.
  HttpTransport({required String url, required this.getToken, http.Client? client})
    : _base = url.replaceFirst(RegExp(r'/+$'), ''),
      _client = client ?? http.Client();

  final String _base;
  final FutureOr<String> Function() getToken;
  final http.Client _client;

  @override
  Future<PushResult> push(String deviceId, List<Map<String, Object?>> ops) async =>
      PushResult.fromJson(
        await _call(deviceId, 'POST', '/v1/push', body: jsonEncode({'ops': ops})),
      );

  @override
  Future<PullResult> pull(String deviceId, int cursor, int limit) async =>
      PullResult.fromJson(await _call(deviceId, 'GET', '/v1/pull?cursor=$cursor&limit=$limit'));

  Future<Map<String, Object?>> _call(
    String deviceId,
    String method,
    String path, {
    String? body,
  }) async {
    final req = http.Request(method, Uri.parse('$_base$path'))
      ..headers['Authorization'] = 'Bearer ${await getToken()}'
      ..headers['Accord-Device'] = deviceId;
    if (body != null) {
      req
        ..headers['Content-Type'] = 'application/json'
        ..body = body;
    }
    final res = await http.Response.fromStream(await _client.send(req));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HttpError(res.statusCode, '$method $path → ${res.statusCode} ${res.body}');
    }
    return jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, Object?>;
  }

  void close() => _client.close();
}
