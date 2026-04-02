import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:validator/validator.dart';

void main() {
  group('validateRepository', () {
    test('passes with valid metadata and members files', () async {
      final root = await _createTempRepo();
      addTearDown(() => root.delete(recursive: true));

      await _writeSchemas(root.path);
      await _writeFile(p.join(root.path, 'teams', 'ABC', 'metadata.yaml'), '''
team_handle: ABC
team_fqdn: Alpha Bravo Club
team_icon_url: https://example.com/icon.png
team_blurb: Valid team blurb
''');
      await _writeFile(p.join(root.path, 'teams', 'ABC', 'members.csv'), '''
discord_name,vrc_name,runstyle,role
user1,Runner One,EC+LS,0
user2,Runner Two,PC,3
''');

      final report = await validateRepository(repoRoot: root.path);
      expect(
        report.isValid,
        isTrue,
        reason: report.errors.map((e) => e.toString()).join('\n'),
      );
      expect(report.filesChecked, 2);
      expect(report.errors, isEmpty);
    });

    test('fails when required metadata field is missing', () async {
      final root = await _createTempRepo();
      addTearDown(() => root.delete(recursive: true));

      await _writeSchemas(root.path);
      await _writeFile(p.join(root.path, 'teams', 'ABC', 'metadata.yaml'), '''
team_handle: ABC
team_fqdn: Alpha Bravo Club
team_icon_url: https://example.com/icon.png
''');

      final report = await validateRepository(repoRoot: root.path);
      expect(report.isValid, isFalse);
      expect(
        report.errors.any((e) => e.toString().contains('team_blurb')),
        isTrue,
      );
    });

    test('fails on invalid members rows and duplicate primary key', () async {
      final root = await _createTempRepo();
      addTearDown(() => root.delete(recursive: true));

      await _writeSchemas(root.path);
      await _writeFile(p.join(root.path, 'teams', 'ABC', 'metadata.yaml'), '''
team_handle: ABC
team_fqdn: Alpha Bravo Club
team_icon_url: ./icon.png
team_blurb: Valid team blurb
''');
      await _writeFile(p.join(root.path, 'teams', 'ABC', 'members.csv'), '''
discord_name,vrc_name,runstyle,role
user1,Runner One,EC+LS,0
user1,Runner Two,PC,-1
''');

      final report = await validateRepository(repoRoot: root.path);
      expect(report.isValid, isFalse);
      expect(
        report.errors.any(
          (e) => e.toString().contains('Duplicate primary key'),
        ),
        isTrue,
        reason: report.errors.map((e) => e.toString()).join('\n'),
      );
      expect(
        report.errors.any((e) => e.toString().contains('Value must be >= 0')),
        isTrue,
      );
    });

    test('passes when teams directory is empty', () async {
      final root = await _createTempRepo();
      addTearDown(() => root.delete(recursive: true));

      await _writeSchemas(root.path);
      await Directory(p.join(root.path, 'teams')).create(recursive: true);

      final report = await validateRepository(repoRoot: root.path);
      expect(report.isValid, isTrue);
      expect(report.filesChecked, 0);
      expect(report.errors, isEmpty);
    });

    test('passes when teams directory does not exist', () async {
      final root = await _createTempRepo();
      addTearDown(() => root.delete(recursive: true));

      await _writeSchemas(root.path);

      final report = await validateRepository(repoRoot: root.path);
      expect(report.isValid, isTrue);
      expect(report.filesChecked, 0);
      expect(report.errors, isEmpty);
    });
  });

  group('findRepoRoot', () {
    test('finds parent directory containing .schema', () async {
      final root = await _createTempRepo();
      addTearDown(() => root.delete(recursive: true));
      await Directory(p.join(root.path, '.schema')).create(recursive: true);

      final nested = Directory(p.join(root.path, 'validator', 'lib'));
      await nested.create(recursive: true);

      final found = findRepoRoot(nested.path);
      expect(found, root.path);
    });
  });
}

Future<Directory> _createTempRepo() {
  return Directory.systemTemp.createTemp('teamdb_validator_test_');
}

Future<void> _writeSchemas(String root) async {
  await _writeFile(
    p.join(root, '.schema', 'metadata.schema.json'),
    jsonEncode({
      r'$schema': 'https://json-schema.org/draft/2020-12/schema',
      'type': 'object',
      'additionalProperties': false,
      'required': ['team_handle', 'team_fqdn', 'team_icon_url', 'team_blurb'],
      'properties': {
        'team_handle': {'type': 'string', 'minLength': 3, 'maxLength': 4},
        'team_fqdn': {'type': 'string', 'minLength': 1, 'maxLength': 64},
        'team_icon_url': {
          'type': 'string',
          'pattern': r'^(https:\/\/.+|\./.+)$',
        },
        'team_blurb': {'type': 'string', 'minLength': 1, 'maxLength': 256},
      },
    }),
  );

  await _writeFile(
    p.join(root, '.schema', 'members.table.schema.json'),
    jsonEncode({
      'fields': [
        {
          'name': 'discord_name',
          'type': 'string',
          'constraints': {'required': true, 'minLength': 1, 'maxLength': 64},
        },
        {
          'name': 'vrc_name',
          'type': 'string',
          'constraints': {'required': true, 'minLength': 1, 'maxLength': 64},
        },
        {
          'name': 'runstyle',
          'type': 'string',
          'constraints': {'required': true, 'minLength': 2, 'maxLength': 32},
        },
        {
          'name': 'role',
          'type': 'integer',
          'constraints': {'required': true, 'minimum': 0},
        },
      ],
      'primaryKey': ['discord_name'],
    }),
  );
}

Future<void> _writeFile(String path, String content) async {
  final file = File(path);
  await file.parent.create(recursive: true);
  await file.writeAsString(content.trimLeft());
}
