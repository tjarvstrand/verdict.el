import 'package:test/test.dart';

void main() {
  print("log from main");

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
    test("a grouped test with output", () {
      print("log from grouped test");
    });
  });

  group('A group with setUp log', () {
    setUp(() {
      print("log from setUp");
    });

    test('test with setUp log', () {});
  });

  group('A group with body log', () {
    print("log from group body");

    test('a test in body-log group', () {});
  });

  group('A group with setUpAll log', () {
    setUpAll(() {
      print("log from setUpAll");
    });

    test('first test after setUpAll', () {});
    test('second test after setUpAll', () {});
  });

  group('A group with tearDownAll log', () {
    tearDownAll(() {
      print("log from tearDownAll");
    });

    test('first test before tearDownAll', () {});
    test('last test before tearDownAll', () {});
  });

  group('A group with tearDown log', () {
    tearDown(() {
      print("log from tearDown");
    });

    test('a test with tearDown log', () {});
  });

  test("a skipped test", () {}, skip: "not yet implemented");

  test("a test with print output", () {
    print("hello from dart");
  });

  group('Outer group', () {
    group('Inner group', () {
      test('a nested test', () {
        print("log from nested test");
      });
    });
  });
}
