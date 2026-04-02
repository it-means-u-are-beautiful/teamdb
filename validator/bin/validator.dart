import 'dart:io';

import 'package:validator/validator.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    _printHelp();
    return;
  }

  String? root;
  var teamsDir = 'teams';
  var includeTemplate = false;

  for (var i = 0; i < arguments.length; i++) {
    final arg = arguments[i];
    if (arg == '--root' && i + 1 < arguments.length) {
      root = arguments[++i];
      continue;
    }
    if (arg == '--teams-dir' && i + 1 < arguments.length) {
      teamsDir = arguments[++i];
      continue;
    }
    if (arg == '--include-template') {
      includeTemplate = true;
      continue;
    }
    stderr.writeln('Unknown argument: $arg');
    _printHelp();
    exitCode = 64;
    return;
  }

  final repoRoot = root ?? findRepoRoot();
  if (repoRoot == null) {
    stderr.writeln('Could not locate repository root containing .schema');
    exitCode = 2;
    return;
  }

  final report = await validateRepository(
    repoRoot: repoRoot,
    teamsDir: teamsDir,
    includeTemplate: includeTemplate,
  );

  if (report.errors.isEmpty) {
    stdout.writeln(
      'Validation passed. Checked ${report.filesChecked} file(s), skipped ${report.filesSkipped}.',
    );
    exitCode = 0;
    return;
  }

  stderr.writeln('Validation failed with ${report.errors.length} error(s):');
  for (final error in report.errors) {
    stderr.writeln('- $error');
  }
  stderr.writeln(
    'Checked ${report.filesChecked} file(s), skipped ${report.filesSkipped}.',
  );
  exitCode = 1;
}

void _printHelp() {
  stdout.writeln('''
TeamDB schema validator

Usage:
  dart run bin/validator.dart [options]

Options:
  --root <path>            Repository root (default: auto-detect by finding .schema)
  --teams-dir <path>       Relative teams directory under root (default: teams)
  --include-template       Also validate files in .template/
  -h, --help               Show this help message
''');
}
