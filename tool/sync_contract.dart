// Refreshes contract/ (golden vectors and protocol schemas) from the Accord repository.
//
//   dart run tool/sync_contract.dart            copy from ../app (ACCORD_APP_DIR to override)
//   dart run tool/sync_contract.dart --check    fail if contract/ differs from the repository (CI)
//
// The contract is committed, so this repository builds and tests alone. A new golden vector in the
// Accord repository must pass here before the next Dart release.
import 'dart:io';

const parts = ['vectors', 'protocol/v1'];

void main(List<String> args) {
  final check = args.contains('--check');
  final app = Directory(Platform.environment['ACCORD_APP_DIR'] ?? '../app');
  if (!File('${app.path}/vectors/lww.json').existsSync()) {
    stderr.writeln('sync_contract: no Accord repository at ${app.path} (set ACCORD_APP_DIR).');
    exit(1);
  }

  final problems = <String>[];
  for (final part in parts) {
    final from = Directory('${app.path}/$part');
    final to = Directory('contract/$part');
    final source = _jsonFiles(from);
    final current = to.existsSync() ? _jsonFiles(to) : <String, String>{};

    for (final name in {...source.keys, ...current.keys}) {
      if (source[name] == current[name]) continue;
      problems.add('$part/$name');
      if (!check) {
        final target = File('${to.path}/$name');
        if (source[name] == null) {
          target.deleteSync();
        } else {
          target.parent.createSync(recursive: true);
          target.writeAsStringSync(source[name]!);
        }
      }
    }
  }

  final commit = Process.runSync('git', ['-C', app.path, 'rev-parse', 'HEAD']);
  final sourceLine = commit.exitCode == 0
      ? 'crossben/accordsync ${(commit.stdout as String).trim()}\n'
      : 'crossben/accordsync (commit unknown)\n';

  if (check) {
    if (problems.isNotEmpty) {
      stderr.writeln('contract/ is behind the Accord repository:');
      for (final p in problems) {
        stderr.writeln('  $p');
      }
      stderr.writeln('Run `dart run tool/sync_contract.dart`, make the tests pass, and commit.');
      exit(1);
    }
    stdout.writeln('contract/ matches the Accord repository.');
    return;
  }
  File('contract/SOURCE').writeAsStringSync(sourceLine);
  stdout.writeln(
    problems.isEmpty ? 'contract/ already up to date.' : 'Updated ${problems.length} file(s).',
  );
}

/// Every `.json` file under [dir], by path relative to it (`random/cases.json`).
Map<String, String> _jsonFiles(Directory dir) => {
  for (final f
      in dir.listSync(recursive: true).whereType<File>().where((f) => f.path.endsWith('.json')))
    f.path.substring(dir.path.length + 1): f.readAsStringSync(),
};
