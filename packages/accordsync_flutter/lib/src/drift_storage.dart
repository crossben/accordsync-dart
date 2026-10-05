import 'dart:async';
import 'dart:convert';

import 'package:accordsync/accordsync.dart';
import 'package:drift/drift.dart';

/// Durable storage in SQLite through drift (ADR-0002). Pass your app's own database: Accord adds
/// four tables prefixed `accord_` (`accord_ops`, `accord_outbox`, `accord_snapshots`,
/// `accord_meta`), the same layout as the TypeScript `SqliteStorage`, and needs no code generation.
///
/// ```dart
/// final storage = DriftStorage(appDatabase); // any GeneratedDatabase
/// ```
final class DriftStorage extends StorageAdapter {
  DriftStorage(this.db, {this.closeDatabase = false});

  final GeneratedDatabase db;

  /// Whether [close] also closes [db]. Leave false when the app keeps using its database.
  final bool closeDatabase;

  Future<void>? _ready;
  Future<void> _queue = Future.value();

  @override
  Future<StorageSnapshot> load() async {
    await _init();
    Future<List<String>> column(String sql, String name) async => [
      for (final row in await db.customSelect(sql).get()) row.read<String>(name),
    ];
    final meta = await column("select v from accord_meta where k = 'meta'", 'v');
    return StorageSnapshot(
      meta: meta.isEmpty
          ? null
          : StoredMeta.fromJson(jsonDecode(meta.first) as Map<String, Object?>),
      snapshots: [
        for (final b in await column('select body from accord_snapshots', 'body'))
          RecordSnapshot.fromJson(jsonDecode(b) as Map<String, Object?>),
      ],
      ops: [
        for (final b in await column('select body from accord_ops', 'body'))
          jsonDecode(b) as Map<String, Object?>,
      ],
      outbox: await column('select op_id from accord_outbox', 'op_id'),
    );
  }

  /// Transactions are queued, so concurrent commits never interleave.
  @override
  Future<void> commit(StorageTx tx) {
    final run = _queue.then((_) => _commit(tx));
    _queue = run.catchError((_) {});
    return run;
  }

  Future<void> _commit(StorageTx tx) async {
    await _init();
    await db.transaction(() async {
      Future<void> run(String sql, [List<Object?> args = const []]) =>
          db.customStatement(sql, args);
      if (tx.clearOps) {
        await run('delete from accord_ops');
        await run('delete from accord_snapshots');
      }
      for (final r in tx.deleteSnapshots) {
        await run('delete from accord_snapshots where record = ?', [r]);
      }
      for (final s in tx.putSnapshots) {
        await run('insert or replace into accord_snapshots (record, body) values (?, ?)', [
          s.record,
          jsonEncode(s.toJson()),
        ]);
      }
      for (final id in tx.deleteOps) {
        await run('delete from accord_ops where op_id = ?', [id]);
      }
      for (final op in tx.putOps) {
        await run('insert or replace into accord_ops (op_id, body) values (?, ?)', [
          op['op_id'],
          jsonEncode(op),
        ]);
      }
      for (final id in tx.outboxAdd) {
        await run('insert or ignore into accord_outbox (op_id) values (?)', [id]);
      }
      for (final id in tx.outboxDelete) {
        await run('delete from accord_outbox where op_id = ?', [id]);
      }
      if (tx.meta != null) {
        await run("insert or replace into accord_meta (k, v) values ('meta', ?)", [
          jsonEncode(tx.meta!.toJson()),
        ]);
      }
    });
  }

  Future<void> _init() => _ready ??= () async {
    for (final sql in [
      'create table if not exists accord_ops (op_id text primary key, body text not null)',
      'create table if not exists accord_outbox (op_id text primary key)',
      'create table if not exists accord_snapshots (record text primary key, body text not null)',
      'create table if not exists accord_meta (k text primary key, v text not null)',
    ]) {
      await db.customStatement(sql);
    }
  }();

  @override
  Future<void> close() async {
    await _queue;
    if (closeDatabase) await db.close();
  }
}

/// A database with no tables of its own, for apps that keep Accord in a separate file.
///
/// ```dart
/// DriftStorage(AccordDatabase(driftDatabase(name: 'accord')), closeDatabase: true)
/// ```
final class AccordDatabase extends GeneratedDatabase {
  AccordDatabase(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
}
