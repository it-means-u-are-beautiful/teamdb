import 'dart:convert';
import 'dart:io';

import 'package:csv/csv.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

// data types

class ValidationError {
  const ValidationError({
    required this.file,
    required this.message,
    this.location,
  });

  final String file;
  final String message;
  final String? location;

  @override
  String toString() {
    final loc = location;
    return (loc == null || loc.isEmpty) ? '$file: $message' : '$file ($loc): $message';
  }
}

class ValidationReport {
  const ValidationReport({
    required this.filesChecked,
    required this.filesSkipped,
    required this.errors,
  });

  final int filesChecked;
  final int filesSkipped;
  final List<ValidationError> errors;

  bool get isValid => errors.isEmpty;
}

// pre-parsed schema representations (avoids repeated casting / null-checks)

class _FieldSchema {
  _FieldSchema({
    required this.name,
    required this.type,
    required this.required,
    this.minLength,
    this.maxLength,
    this.minInt,
    this.maxInt,
    this.pattern,
  }) : _regex = pattern != null && pattern.isNotEmpty ? RegExp(pattern) : null;

  final String name;
  final String type; 
  final bool required;
  final int? minLength;
  final int? maxLength;
  final int? minInt;
  final int? maxInt;
  final String? pattern;
  final RegExp? _regex; // compiled once

  RegExp? get regex => _regex;

  factory _FieldSchema.fromMap(Map<String, dynamic> m) {
    final c = (m['constraints'] is Map)
        ? (m['constraints'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    return _FieldSchema(
      name: (m['name'] ?? '').toString(),
      type: (m['type'] ?? '').toString(),
      required: c['required'] == true,
      minLength: _asInt(c['minLength']),
      maxLength: _asInt(c['maxLength']),
      minInt: _asInt(c['minimum']),
      maxInt: _asInt(c['maximum']),
      pattern: null, // only used for YAML metadata fields
    );
  }
}

class _MembersSchema {
  _MembersSchema({required this.fields, required this.primaryKey});

  final List<_FieldSchema> fields;
  final List<String> primaryKey;

  factory _MembersSchema.fromJson(Map<String, dynamic> json) {
    final fields = (json['fields'] as List? ?? [])
        .whereType<Map>()
        .map((e) => _FieldSchema.fromMap(e.cast<String, dynamic>()))
        .toList(growable: false);
    final pk = (json['primaryKey'] as List? ?? [])
        .map((e) => e.toString())
        .toList(growable: false);
    return _MembersSchema(fields: fields, primaryKey: pk);
  }

  List<String> get expectedHeaders => fields.map((f) => f.name).toList(growable: false);
}

class _MetadataSchema {
  _MetadataSchema({
    required this.required,
    required this.properties,
    required this.allowAdditional,
  });

  final Set<String> required;
  final Map<String, _FieldSchema> properties;
  final bool allowAdditional;

  factory _MetadataSchema.fromJson(Map<String, dynamic> json) {
    final req = (json['required'] as List? ?? [])
        .map((e) => e.toString())
        .toSet();
    final raw = (json['properties'] is Map)
        ? (json['properties'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final props = <String, _FieldSchema>{};
    for (final entry in raw.entries) {
      if (entry.value is! Map) continue;
      final m = (entry.value as Map).cast<String, dynamic>();
      props[entry.key] = _FieldSchema(
        name: entry.key,
        type: (m['type'] ?? '').toString(),
        required: req.contains(entry.key),
        minLength: _asInt(m['minLength']),
        maxLength: _asInt(m['maxLength']),
        minInt: _asInt(m['minimum']),
        maxInt: _asInt(m['maximum']),
        pattern: m['pattern']?.toString(),
      );
    }
    return _MetadataSchema(
      required: req,
      properties: props,
      allowAdditional: json['additionalProperties'] != false,
    );
  }
}

// validator

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
    final metadataSchema = _MetadataSchema.fromJson(
      await _readJson(p.join(repoRoot, '.schema', 'metadata.schema.json')),
    );
    final membersSchema = _MembersSchema.fromJson(
      await _readJson(p.join(repoRoot, '.schema', 'members.table.schema.json')),
    );

    final errors = <ValidationError>[];
    var checked = 0;
    var skipped = 0;

    final roots = [
      p.join(repoRoot, teamsDir),
      if (includeTemplate) p.join(repoRoot, '.template'),
    ];

    for (final rootPath in roots) {
      final root = Directory(rootPath);
      if (!await root.exists()) continue;

      await for (final entity in root.list(recursive: true, followLinks: false)) {
        if (entity is! File) continue;

        final basename = p.basename(entity.path).toLowerCase();

        if (basename == 'metadata.yaml' || basename == 'metadata.yml') {
          checked++;
          errors.addAll(await _validateMetadataYaml(entity, metadataSchema));
        } else if (basename == 'members.csv') {
          checked++;
          errors.addAll(await _validateMembersCsv(entity, membersSchema));
        } else if (basename.endsWith('.yaml') ||
            basename.endsWith('.yml') ||
            basename.endsWith('.csv')) {
          skipped++;
        }
      }
    }

    return ValidationReport(
      filesChecked: checked,
      filesSkipped: skipped,
      errors: errors,
    );
  }

  // YAML metadata

  Future<List<ValidationError>> _validateMetadataYaml(
    File file,
    _MetadataSchema schema,
  ) async {
    final errors = <ValidationError>[];
    final rel = _relative(file.path);
    final content = await file.readAsString();

    dynamic decoded;
    try {
      decoded = loadYaml(content);
    } catch (e) {
      return [ValidationError(file: rel, message: 'Invalid YAML: $e')];
    }

    final value = _yamlToJson(decoded);
    if (value is! Map<String, dynamic>) {
      return [ValidationError(file: rel, message: 'Expected a YAML object at top level')];
    }

    for (final key in schema.required) {
      if (!value.containsKey(key)) {
        errors.add(ValidationError(file: rel, location: key, message: 'Missing required field'));
      }
    }

    for (final entry in value.entries) {
      final key = entry.key;
      final fieldSchema = schema.properties[key];

      if (fieldSchema == null) {
        if (!schema.allowAdditional) {
          errors.add(ValidationError(
            file: rel,
            location: key,
            message: 'Unexpected field (additionalProperties=false)',
          ));
        }
        continue;
      }

      errors.addAll(_validateScalarField(entry.value, fieldSchema, rel, key));
    }

    return errors;
  }
  
  // CSV members

  Future<List<ValidationError>> _validateMembersCsv(
    File file,
    _MembersSchema schema,
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
      return [ValidationError(file: rel, message: 'Invalid CSV: $e')];
    }
    rows.removeWhere(_isEmptyCsvRow);

    if (rows.isEmpty) {
      return [ValidationError(file: rel, message: 'CSV must include a header row')];
    }

    final expectedHeaders = schema.expectedHeaders;
    final header = rows.first.map((c) => c.toString().trim()).toList(growable: false);

    if (header.length != expectedHeaders.length) {
      return [
        ValidationError(
          file: rel,
          location: 'row 1',
          message:
              'Header column count mismatch: expected ${expectedHeaders.length}, got ${header.length}',
        ),
      ];
    }

    for (var i = 0; i < expectedHeaders.length; i++) {
      if (header[i] != expectedHeaders[i]) {
        errors.add(ValidationError(
          file: rel,
          location: 'row 1, column ${i + 1}',
          message: 'Expected header "${expectedHeaders[i]}", got "${header[i]}"',
        ));
      }
    }

    final primaryKey = schema.primaryKey;
    final seenPrimaryKeys = <String>{};
    final fields = schema.fields;

    for (var rowIndex = 1; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];
      final line = rowIndex + 1;

      if (row.length != header.length) {
        errors.add(ValidationError(
          file: rel,
          location: 'row $line',
          message: 'Column count mismatch: expected ${header.length}, got ${row.length}',
        ));
        continue;
      }

      final rowMap = <String, String>{
        for (var i = 0; i < header.length; i++) header[i]: row[i].toString().trim(),
      };

      for (final field in fields) {
        final raw = rowMap[field.name] ?? '';
        final location = 'row $line, field ${field.name}';

        if (field.required && raw.isEmpty) {
          errors.add(ValidationError(file: rel, location: location, message: 'Value is required'));
          continue;
        }

        if (field.type == 'string') {
          _checkStringLength(raw, field, rel, location, errors);
        } else if (field.type == 'integer') {
          final parsed = int.tryParse(raw);
          if (parsed == null) {
            errors.add(ValidationError(
              file: rel,
              location: location,
              message: 'Expected integer, got "$raw"',
            ));
            continue;
          }
          _checkIntBounds(parsed, field, rel, location, errors);
        }
      }

      if (primaryKey.isNotEmpty) {
        final keyValue = primaryKey.map((k) => rowMap[k] ?? '').join('\x00');
        if (!seenPrimaryKeys.add(keyValue)) {
          errors.add(ValidationError(
            file: rel,
            location: 'row $line',
            message: 'Duplicate primary key: ${primaryKey.join(', ')}',
          ));
        }
      }
    }

    return errors;
  }
  
  // shared field validators

  /// validates a single scalar YAML field value against its [_FieldSchema].
  List<ValidationError> _validateScalarField(
    dynamic value,
    _FieldSchema schema,
    String file,
    String location,
  ) {
    final errors = <ValidationError>[];

    if (schema.type == 'string') {
      if (value is! String) {
        return [ValidationError(file: file, location: location, message: 'Expected string')];
      }
      _checkStringLength(value, schema, file, location, errors);
      final regex = schema.regex;
      if (regex != null && !regex.hasMatch(value)) {
        errors.add(ValidationError(
          file: file,
          location: location,
          message: 'Value does not match pattern ${schema.pattern}',
        ));
      }
    } else if (schema.type == 'integer') {
      if (value is! int) {
        return [ValidationError(file: file, location: location, message: 'Expected integer')];
      }
      _checkIntBounds(value, schema, file, location, errors);
    }

    return errors;
  }

  static void _checkStringLength(
    String value,
    _FieldSchema schema,
    String file,
    String location,
    List<ValidationError> errors,
  ) {
    final len = value.length;
    if (schema.minLength case final min? when len < min) {
      errors.add(ValidationError(
        file: file,
        location: location,
        message: 'Length must be >= $min, got $len',
      ));
    }
    if (schema.maxLength case final max? when len > max) {
      errors.add(ValidationError(
        file: file,
        location: location,
        message: 'Length must be <= $max, got $len',
      ));
    }
  }

  static void _checkIntBounds(
    int value,
    _FieldSchema schema,
    String file,
    String location,
    List<ValidationError> errors,
  ) {
    if (schema.minInt case final min? when value < min) {
      errors.add(ValidationError(
        file: file,
        location: location,
        message: 'Value must be >= $min, got $value',
      ));
    }
    if (schema.maxInt case final max? when value > max) {
      errors.add(ValidationError(
        file: file,
        location: location,
        message: 'Value must be <= $max, got $value',
      ));
    }
  }

  // helpers

  static bool _isEmptyCsvRow(List<dynamic> row) =>
      row.every((cell) => cell.toString().trim().isEmpty);

  String _relative(String absolutePath) => p.relative(absolutePath, from: repoRoot);
}

// public API

Future<ValidationReport> validateRepository({
  required String repoRoot,
  String teamsDir = 'teams',
  bool includeTemplate = false,
}) =>
    TeamDbValidator(
      repoRoot: repoRoot,
      teamsDir: teamsDir,
      includeTemplate: includeTemplate,
    ).validate();

String? findRepoRoot([String? startPath]) {
  var cursor = Directory(startPath ?? Directory.current.path).absolute;
  while (true) {
    if (Directory(p.join(cursor.path, '.schema')).existsSync()) return cursor.path;
    final parent = cursor.parent;
    if (parent.path == cursor.path) return null;
    cursor = parent;
  }
}

// internal utilities

Future<Map<String, dynamic>> _readJson(String path) async {
  final decoded = jsonDecode(await File(path).readAsString());
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Schema root must be an object');
  }
  return decoded;
}

dynamic _yamlToJson(dynamic value) => switch (value) {
      YamlMap() => <String, dynamic>{
          for (final e in value.entries) e.key.toString(): _yamlToJson(e.value),
        },
      YamlList() => [for (final e in value) _yamlToJson(e)],
      _ => value,
    };

int? _asInt(dynamic value) => switch (value) {
      int() => value,
      num() => value.toInt(),
      String() => int.tryParse(value),
      _ => null,
    };
