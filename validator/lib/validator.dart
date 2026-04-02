import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

class ValidationError {
  ValidationError({required this.file, required this.message, this.location});

  final String file;
  final String message;
  final String? location;

  @override
  String toString() {
    if (location == null || location!.isEmpty) {
      return '$file: $message';
    }
    return '$file ($location): $message';
  }
}

class ValidationReport {
  ValidationReport({
    required this.filesChecked,
    required this.filesSkipped,
    required this.errors,
  });

  final int filesChecked;
  final int filesSkipped;
  final List<ValidationError> errors;

  bool get isValid => errors.isEmpty;
}

class TeamDbValidator {
  TeamDbValidator({
    required this.repoRoot,
    this.teamsDir = 'teams',
    this.includeTemplate = false,
  });

  final String repoRoot;
  final String teamsDir;
  final bool includeTemplate;

  Future<ValidationReport> validate() async {
    final metadataSchema = await _readJson(
      p.join(repoRoot, '.schema', 'metadata.schema.json'),
    );
    final membersSchema = await _readJson(
      p.join(repoRoot, '.schema', 'members.table.schema.json'),
    );

    final errors = <ValidationError>[];
    var checked = 0;
    var skipped = 0;

    final roots = <String>[p.join(repoRoot, teamsDir)];
    if (includeTemplate) {
      roots.add(p.join(repoRoot, '.template'));
    }

    for (final rootPath in roots) {
      final root = Directory(rootPath);
      if (!await root.exists()) {
        continue;
      }

      await for (final entity in root.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) {
          continue;
        }

        final basename = p.basename(entity.path).toLowerCase();
        final isYaml = basename.endsWith('.yaml') || basename.endsWith('.yml');
        final isCsv = basename.endsWith('.csv');

        if (!isYaml && !isCsv) {
          continue;
        }

        if (basename == 'metadata.yaml' || basename == 'metadata.yml') {
          checked += 1;
          errors.addAll(await _validateMetadataYaml(entity, metadataSchema));
          continue;
        }

        if (basename == 'members.csv') {
          checked += 1;
          errors.addAll(await _validateMembersCsv(entity, membersSchema));
          continue;
        }

        skipped += 1;
      }
    }

    return ValidationReport(
      filesChecked: checked,
      filesSkipped: skipped,
      errors: errors,
    );
  }

  Future<List<ValidationError>> _validateMetadataYaml(
    File file,
    Map<String, dynamic> schema,
  ) async {
    final errors = <ValidationError>[];
    final rel = _relative(file.path);
    final content = await file.readAsString();

    dynamic decoded;
    try {
      decoded = loadYaml(content);
    } catch (e) {
      errors.add(ValidationError(file: rel, message: 'Invalid YAML: $e'));
      return errors;
    }

    final value = _yamlToJson(decoded);
    if (value is! Map<String, dynamic>) {
      errors.add(
        ValidationError(
          file: rel,
          message: 'Expected a YAML object at top level',
        ),
      );
      return errors;
    }

    errors.addAll(_validateJsonObject(value, schema, rel));
    return errors;
  }

  Future<List<ValidationError>> _validateMembersCsv(
    File file,
    Map<String, dynamic> schema,
  ) async {
    final errors = <ValidationError>[];
    final rel = _relative(file.path);
    final content = await file.readAsString();

    List<List<dynamic>> rows;
    try {
      rows = const CsvToListConverter(
        shouldParseNumbers: false,
        allowInvalid: false,
        eol: '\n',
      ).convert(content);
    } catch (e) {
      errors.add(ValidationError(file: rel, message: 'Invalid CSV: $e'));
      return errors;
    }

    rows = rows.where((row) => !_isEmptyCsvRow(row)).toList();

    if (rows.isEmpty) {
      errors.add(
        ValidationError(file: rel, message: 'CSV must include a header row'),
      );
      return errors;
    }

    final fields =
        (schema['fields'] as List?)
            ?.whereType<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList() ??
        <Map<String, dynamic>>[];

    final expectedHeaders = fields
        .map((f) => (f['name'] ?? '').toString())
        .where((name) => name.isNotEmpty)
        .toList();
    final header = rows.first.map((cell) => cell.toString().trim()).toList();

    if (header.length != expectedHeaders.length) {
      errors.add(
        ValidationError(
          file: rel,
          location: 'row 1',
          message:
              'Header column count mismatch: expected ${expectedHeaders.length}, got ${header.length}',
        ),
      );
      return errors;
    }

    for (var i = 0; i < expectedHeaders.length; i++) {
      if (header[i] != expectedHeaders[i]) {
        errors.add(
          ValidationError(
            file: rel,
            location: 'row 1, column ${i + 1}',
            message:
                'Expected header "${expectedHeaders[i]}", got "${header[i]}"',
          ),
        );
      }
    }

    final primaryKey =
        (schema['primaryKey'] as List?)?.map((e) => e.toString()).toList() ??
        const <String>[];
    final seenPrimaryKeys = <String>{};

    for (var rowIndex = 1; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];
      final line = rowIndex + 1;

      if (row.length != header.length) {
        errors.add(
          ValidationError(
            file: rel,
            location: 'row $line',
            message:
                'Column count mismatch: expected ${header.length}, got ${row.length}',
          ),
        );
        continue;
      }

      final rowMap = <String, String>{
        for (var i = 0; i < header.length; i++)
          header[i]: row[i].toString().trim(),
      };

      for (final field in fields) {
        final name = (field['name'] ?? '').toString();
        final type = (field['type'] ?? '').toString();
        final constraints = (field['constraints'] is Map)
            ? (field['constraints'] as Map).cast<String, dynamic>()
            : const <String, dynamic>{};

        final raw = rowMap[name] ?? '';
        final location = 'row $line, field $name';

        if ((constraints['required'] == true) && raw.isEmpty) {
          errors.add(
            ValidationError(
              file: rel,
              location: location,
              message: 'Value is required',
            ),
          );
          continue;
        }

        if (type == 'string') {
          final minLength = _asInt(constraints['minLength']);
          final maxLength = _asInt(constraints['maxLength']);
          if (minLength != null && raw.length < minLength) {
            errors.add(
              ValidationError(
                file: rel,
                location: location,
                message: 'Length must be >= $minLength, got ${raw.length}',
              ),
            );
          }
          if (maxLength != null && raw.length > maxLength) {
            errors.add(
              ValidationError(
                file: rel,
                location: location,
                message: 'Length must be <= $maxLength, got ${raw.length}',
              ),
            );
          }
        } else if (type == 'integer') {
          final parsed = int.tryParse(raw);
          if (parsed == null) {
            errors.add(
              ValidationError(
                file: rel,
                location: location,
                message: 'Expected integer, got "$raw"',
              ),
            );
            continue;
          }

          final minimum = _asInt(constraints['minimum']);
          final maximum = _asInt(constraints['maximum']);
          if (minimum != null && parsed < minimum) {
            errors.add(
              ValidationError(
                file: rel,
                location: location,
                message: 'Value must be >= $minimum, got $parsed',
              ),
            );
          }
          if (maximum != null && parsed > maximum) {
            errors.add(
              ValidationError(
                file: rel,
                location: location,
                message: 'Value must be <= $maximum, got $parsed',
              ),
            );
          }
        }
      }

      if (primaryKey.isNotEmpty) {
        final keyValue = primaryKey.map((k) => rowMap[k] ?? '').join('\u0000');
        if (seenPrimaryKeys.contains(keyValue)) {
          errors.add(
            ValidationError(
              file: rel,
              location: 'row $line',
              message: 'Duplicate primary key: ${primaryKey.join(', ')}',
            ),
          );
        } else {
          seenPrimaryKeys.add(keyValue);
        }
      }
    }

    return errors;
  }

  bool _isEmptyCsvRow(List<dynamic> row) {
    for (final cell in row) {
      if (cell.toString().trim().isNotEmpty) {
        return false;
      }
    }
    return true;
  }

  List<ValidationError> _validateJsonObject(
    Map<String, dynamic> value,
    Map<String, dynamic> schema,
    String file,
  ) {
    final errors = <ValidationError>[];

    final required =
        (schema['required'] as List?)?.map((e) => e.toString()).toSet() ??
        <String>{};
    final properties = (schema['properties'] is Map)
        ? (schema['properties'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final allowAdditional = schema['additionalProperties'] != false;

    for (final key in required) {
      if (!value.containsKey(key)) {
        errors.add(
          ValidationError(
            file: file,
            location: key,
            message: 'Missing required field',
          ),
        );
      }
    }

    for (final entry in value.entries) {
      final key = entry.key;
      final fieldSchema = properties[key];
      if (fieldSchema == null) {
        if (!allowAdditional) {
          errors.add(
            ValidationError(
              file: file,
              location: key,
              message: 'Unexpected field (additionalProperties=false)',
            ),
          );
        }
        continue;
      }

      if (fieldSchema is! Map) {
        continue;
      }

      final typedSchema = fieldSchema.cast<String, dynamic>();
      final type = (typedSchema['type'] ?? '').toString();
      final fieldValue = entry.value;

      if (type == 'string') {
        if (fieldValue is! String) {
          errors.add(
            ValidationError(
              file: file,
              location: key,
              message: 'Expected string',
            ),
          );
          continue;
        }

        final minLength = _asInt(typedSchema['minLength']);
        final maxLength = _asInt(typedSchema['maxLength']);
        final pattern = typedSchema['pattern']?.toString();

        if (minLength != null && fieldValue.length < minLength) {
          errors.add(
            ValidationError(
              file: file,
              location: key,
              message: 'Length must be >= $minLength, got ${fieldValue.length}',
            ),
          );
        }

        if (maxLength != null && fieldValue.length > maxLength) {
          errors.add(
            ValidationError(
              file: file,
              location: key,
              message: 'Length must be <= $maxLength, got ${fieldValue.length}',
            ),
          );
        }

        if (pattern != null && pattern.isNotEmpty) {
          final regex = RegExp(pattern);
          if (!regex.hasMatch(fieldValue)) {
            errors.add(
              ValidationError(
                file: file,
                location: key,
                message: 'Value does not match pattern $pattern',
              ),
            );
          }
        }
      } else if (type == 'integer') {
        if (fieldValue is! int) {
          errors.add(
            ValidationError(
              file: file,
              location: key,
              message: 'Expected integer',
            ),
          );
          continue;
        }
        final minimum = _asInt(typedSchema['minimum']);
        final maximum = _asInt(typedSchema['maximum']);
        if (minimum != null && fieldValue < minimum) {
          errors.add(
            ValidationError(
              file: file,
              location: key,
              message: 'Value must be >= $minimum, got $fieldValue',
            ),
          );
        }
        if (maximum != null && fieldValue > maximum) {
          errors.add(
            ValidationError(
              file: file,
              location: key,
              message: 'Value must be <= $maximum, got $fieldValue',
            ),
          );
        }
      }
    }

    return errors;
  }

  String _relative(String absolutePath) {
    return p.relative(absolutePath, from: repoRoot);
  }
}

Future<ValidationReport> validateRepository({
  required String repoRoot,
  String teamsDir = 'teams',
  bool includeTemplate = false,
}) {
  return TeamDbValidator(
    repoRoot: repoRoot,
    teamsDir: teamsDir,
    includeTemplate: includeTemplate,
  ).validate();
}

String? findRepoRoot([String? startPath]) {
  var cursor = Directory(startPath ?? Directory.current.path).absolute;
  while (true) {
    final schemaDir = Directory(p.join(cursor.path, '.schema'));
    if (schemaDir.existsSync()) {
      return cursor.path;
    }

    final parent = cursor.parent;
    if (parent.path == cursor.path) {
      return null;
    }
    cursor = parent;
  }
}

Future<Map<String, dynamic>> _readJson(String path) async {
  final content = await File(path).readAsString();
  final decoded = jsonDecode(content);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Schema root must be an object');
  }
  return decoded;
}

dynamic _yamlToJson(dynamic value) {
  if (value is YamlMap) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key.toString(): _yamlToJson(entry.value),
    };
  }
  if (value is YamlList) {
    return value.map(_yamlToJson).toList();
  }
  return value;
}

int? _asInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}
