import 'dart:io';

import 'package:validator/validator.dart';

// this is where we enter twan

Future<void> main(List<String> arguments) async {
  if (arguments.contains('--help') || arguments.contains('-h')) {
    _printHelp();
    return;
  }

   // arg parsing here

  String? root;
  var teamsDir = 'teams';
  var includeTemplate = false;

  for (var i = 0; i < arguments.length; i++) {
    final arg = arguments[i];
    switch (arg) {
      case '--root' when i + 1 < arguments.length:
        root = arguments[++i];
      case '--teams-dir' when i + 1 < arguments.length:
        teamsDir = arguments[++i];
      case '--include-template':
        includeTemplate = true;
      default:
        stderr.writeln('Unknown argument: $arg');
        _printHelp();
        exitCode = 64;
        return;
    }
  }

  // validation

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

  // output

  if (report.errors.isEmpty) {
    stdout.writeln(
      'Validation passed. Checked ${report.filesChecked} file(s), skipped ${report.filesSkipped}.',
    );
    return; // exitCode defaults to 0
  }

  stderr.writeln('Validation failed with ${report.errors.length} error(s):');
  for (final error in report.errors) {
    stderr.writeln('- $error');
  }
  stderr.writeln('Checked ${report.filesChecked} file(s), skipped ${report.filesSkipped}.');
  exitCode = 1;
}

void _printHelp() {
  stdout.writeln('''
TeamDB schema validator

Usage:
  dart run bin/validator.dart [options]

Options:
  --root <path>        Repository root (default: auto-detect by finding .schema)
  --teams-dir <path>   Relative teams directory under root (default: teams)
  --include-template   Also validate files in .template/
  -h, --help           Show this help message
''');
}
