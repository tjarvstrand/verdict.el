import 'package:test/test.dart';

void main() {
  test("a top-level test that succeeds", () {});
  test("a top-level test that fails", () => throw Exception());

  group('A group of tests that fails during setUp', () {
    setUp(() {
      throw Exception();
    });

    test('First Test', () {});
  });

  group('A group of tests that fails during setUpAll', () {
    setUpAll(() {
      throw Exception();
    });

    test('First Test', () {});
  });

  group('A group of tests that fails during setUpAll', () {
    setUpAll(() {
      throw Exception();
    });

    test('First Test', () {});
  });

  group('A group', () {
    test("a grouped test that succeeds", () {});
    test("a grouped test that fails", () => throw Exception());
  });
}
