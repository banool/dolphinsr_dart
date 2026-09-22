import 'dart:math' as math;
import 'package:dolphinsr/dolphinsr.dart';
import 'package:test/test.dart';

const Combination drawing = Combination(front: <int>[0], back: <int>[1]);
const Combination reversed = Combination(front: <int>[1], back: <int>[0]);
const List<String> fields = <String>['Hello', 'world'];

String generateId() {
  return math.Random().nextInt(666).toString();
}

DolphinSR withMaster(String id, List<Combination> combinations) {
  final d = DolphinSR(outOfOrderReviewPolicy: OutOfOrderReviewPolicy.skip);
  d.addMasters([Master(id: id, fields: fields, combinations: combinations)]);
  return d;
}

DRCard cardFor(DolphinSR d, Combination c) =>
    d.getAllCardState().firstWhere((card) => card.combination == c);

void main() {
  test('should create a card for each added combination', () {
    final id = generateId();
    final d = withMaster(id, [drawing]);
    expect(d.cardsLength(), equals(1));

    d.addCombinations(id, [reversed]);

    expect(d.cardsLength(), equals(2));
    expect(cardFor(d, reversed).lastReviewed, isNull);
  });

  test('should let a review for the added combination apply', () {
    final id = generateId();
    final d = withMaster(id, [drawing]);
    final review = Review(
      master: id,
      combination: reversed,
      ts: DateTime(2026, 1, 1),
      rating: Rating.Good,
    );

    expect(() => d.addReviews([review]), throwsA(isA<UnknownCardException>()));

    d.addCombinations(id, [reversed]);
    d.addReviews([review]);

    expect(cardFor(d, reversed).lastReviewed, equals(DateTime(2026, 1, 1)));
  });

  test('should leave existing cards and their schedule untouched', () {
    final id = generateId();
    final d = withMaster(id, [drawing]);
    d.addReviews([
      Review(
        master: id,
        combination: drawing,
        ts: DateTime(2026, 1, 1),
        rating: Rating.Good,
      ),
    ]);
    final before = cardFor(d, drawing);

    d.addCombinations(id, [reversed]);

    final after = cardFor(d, drawing);
    expect(after.lastReviewed, equals(before.lastReviewed));
    expect(after.dueDate, equals(before.dueDate));
  });

  test('should ignore combinations the master already has', () {
    final id = generateId();
    final d = withMaster(id, [drawing]);
    d.addReviews([
      Review(
        master: id,
        combination: drawing,
        ts: DateTime(2026, 1, 1),
        rating: Rating.Good,
      ),
    ]);
    final before = cardFor(d, drawing);

    d.addCombinations(id, [drawing, drawing]);

    expect(d.cardsLength(), equals(1));
    expect(cardFor(d, drawing).lastReviewed, equals(before.lastReviewed));
  });

  test('should deduplicate combinations within a single call', () {
    final id = generateId();
    final d = withMaster(id, [drawing]);

    d.addCombinations(id, [reversed, reversed]);

    expect(d.cardsLength(), equals(2));
  });

  test('should keep the widened combinations on the master', () {
    final id = generateId();
    final d = withMaster(id, [drawing]);
    d.addCombinations(id, [reversed]);

    // removeFromMaster walks the master's own combinations, so a widened
    // master must carry them or it would leak card states.
    d.removeFromMaster(id);

    expect(d.cardsLength(), equals(0));
    expect(d.cardExistInMaster(id), isFalse);
  });

  test('should make the new card schedulable', () {
    final id = generateId();
    final d = withMaster(id, [drawing]);
    d.addReviews([
      Review(
        master: id,
        combination: drawing,
        ts: DateTime(2026, 1, 1),
        rating: Rating.Easy,
      ),
    ]);

    d.addCombinations(id, [reversed]);

    expect(d.summary().learning, equals(1));
    expect(d.nextCard()?.combination, equals(reversed));
  });

  test('should throw when the master is not registered', () {
    final d = DolphinSR();
    expect(() => d.addCombinations(generateId(), [drawing]),
        throwsA(isA<UnknownMasterException>()));
  });
}
