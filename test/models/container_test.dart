import 'package:flutter_test/flutter_test.dart';
import 'package:pockr/models/container.dart';

void main() {
  group('Container', () {
    test('fromJson parses all fields, defaulting missing ports to empty', () {
      final container = Container.fromJson({
        'name': 'web',
        'image': 'nginx:latest',
        'status': 'running',
        'ports': ['80:80', '443:443'],
      });

      expect(container.name, 'web');
      expect(container.image, 'nginx:latest');
      expect(container.status, 'running');
      expect(container.ports, ['80:80', '443:443']);
    });

    test('fromJson defaults ports to an empty list when absent', () {
      final container = Container.fromJson({
        'name': 'redis',
        'image': 'redis:7',
        'status': 'stopped',
      });

      expect(container.ports, isEmpty);
    });

    test('toJson round-trips through fromJson', () {
      final original = Container(
        name: 'db',
        image: 'postgres:16',
        status: 'running',
        ports: ['5432:5432'],
      );

      final roundTripped = Container.fromJson(original.toJson());

      expect(roundTripped.name, original.name);
      expect(roundTripped.image, original.image);
      expect(roundTripped.status, original.status);
      expect(roundTripped.ports, original.ports);
    });
  });
}
