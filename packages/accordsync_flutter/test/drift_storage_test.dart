import 'dart:io';

import 'package:accordsync_flutter/accordsync_flutter.dart';
import 'package:accordsync_testing/storage_contract.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  storageContract('drift', () {
    final file = File('${Directory.systemTemp.createTempSync('accord-').path}/a.db');
    DriftStorage open() => DriftStorage(AccordDatabase(NativeDatabase(file)), closeDatabase: true);
    return (store: open(), reopen: open);
  });

  test('a failed transaction leaves nothing behind', () async {
    final db = AccordDatabase(NativeDatabase.memory());
    final store = DriftStorage(db);
    final meta1 = const StoredMeta(deviceId: 'd', cursor: 1, hlc: '1:00000:d', seq: 1);
    await store.commit(
      StorageTx(
        putOps: [
          {'op_id': 'd:1', 'record': 'dossier:1'},
        ],
        meta: meta1,
      ),
    );
    // A trigger makes the outbox insert fail, after the op insert succeeded.
    await db.customStatement(
      "create trigger boom before insert on accord_outbox begin select raise(abort, 'disk full'); end",
    );
    await expectLater(
      store.commit(
        StorageTx(
          putOps: [
            {'op_id': 'd:2', 'record': 'dossier:1'},
          ],
          outboxAdd: ['d:2'],
          meta: const StoredMeta(deviceId: 'd', cursor: 2, hlc: '2:00000:d', seq: 2),
        ),
      ),
      throwsA(anything),
    );
    final s = await store.load();
    expect(s.ops.map((o) => o['op_id']), ['d:1']);
    expect(s.meta, meta1);
  });

  test('shares an app database: Accord tables sit next to the app\'s own', () async {
    final db = AccordDatabase(NativeDatabase.memory());
    await db.customStatement('create table notes (id integer primary key, body text)');
    final store = DriftStorage(db);
    await store.commit(const StorageTx(outboxAdd: ['d:1']));
    final tables = await db
        .customSelect("select name from sqlite_master where type = 'table' order by name")
        .get();
    expect(tables.map((r) => r.read<String>('name')), [
      'accord_meta',
      'accord_ops',
      'accord_outbox',
      'accord_snapshots',
      'notes',
    ]);
  });
}
