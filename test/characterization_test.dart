import 'dart:math' as math;
import 'package:dolphinsr/dolphinsr.dart';
import 'package:dolphinsr/src/utils.dart';
import 'package:test/test.dart';

// Characterization tests: these pin down the library's current observable
// behavior (state transitions, schedule math, card selection order) so the
// planned refactors can prove they change only what they intend to change.

Combination combo01() => const Combination(front: [0], back: [1]);

LearningCardState freshCard(String id) =>
    makeInitialCardState(id: id, combination: combo01());

Review reviewFor(String id, DateTime ts, Rating rating) =>
    Review(master: id, combination: combo01(), ts: ts, rating: rating);

void main() {
  final t0 = DateTime(2026, 1, 10, 8, 30);

  group('applyToLearningCardState matrix', () {
    LearningCardState learning(int consecutiveCorrect) => LearningCardState(
        master: 'm',
        combination: combo01(),
        consecutiveCorrect: consecutiveCorrect,
        lastReviewed: null);

    test('Again resets consecutiveCorrect, stays learning', () {
      final next = applyToCardState(learning(1), t0, Rating.Again);
      expect(next, isA<LearningCardState>());
      expect((next as LearningCardState).consecutiveCorrect, 0);
      expect(next.lastReviewed, t0);
    });

    test('Hard resets consecutiveCorrect, stays learning', () {
      final next = applyToCardState(learning(1), t0, Rating.Hard);
      expect(next, isA<LearningCardState>());
      expect((next as LearningCardState).consecutiveCorrect, 0);
    });

    test('Good on a first-time card increments consecutiveCorrect', () {
      final next = applyToCardState(learning(0), t0, Rating.Good);
      expect(next, isA<LearningCardState>());
      expect((next as LearningCardState).consecutiveCorrect, 1);
    });

    test('Good after one correct graduates to reviewing at 4 days', () {
      final next = applyToCardState(learning(1), t0, Rating.Good);
      expect(next, isA<ReviewingCardState>());
      final r = next as ReviewingCardState;
      expect(r.factor, 2500);
      expect(r.lapses, 0);
      expect(r.interval, 4.0);
      expect(r.lastReviewed, t0);
    });

    test('Easy on a first-time card jump-graduates at 1 day', () {
      final next = applyToCardState(learning(0), t0, Rating.Easy);
      expect(next, isA<ReviewingCardState>());
      expect((next as ReviewingCardState).interval, 1.0);
    });

    test('Easy after one correct graduates at 4 days', () {
      final next = applyToCardState(learning(1), t0, Rating.Easy);
      expect(next, isA<ReviewingCardState>());
      expect((next as ReviewingCardState).interval, 4.0);
    });
  });

  group('applyToReviewingCardState matrix', () {
    ReviewingCardState reviewing(
            {double factor = 2500, double interval = 4.0}) =>
        ReviewingCardState(
            master: 'm',
            combination: combo01(),
            factor: factor,
            lapses: 0,
            interval: interval,
            lastReviewed: t0);

    // interval 4.0 from t0 (Jan 10, 08:30) is due Jan 14 at 03:30 (the due
    // date pins the hour to 3 but keeps minutes/seconds — see the
    // calculateDueDate goldens below).
    final onTime = DateTime(2026, 1, 14, 3, 30);

    test('Again lapses: factor -200, lapses +1, interval kept', () {
      final next = applyToCardState(reviewing(), onTime, Rating.Again);
      expect(next, isA<LapsedCardState>());
      final l = next as LapsedCardState;
      expect(l.factor, 2300);
      expect(l.lapses, 1);
      expect(l.interval, 4.0);
      expect(l.consecutiveCorrect, 0);
      expect(l.lastReviewed, onTime);
    });

    test('Good on time: interval * factor/1000, factor unchanged', () {
      final next = applyToCardState(reviewing(), onTime, Rating.Good);
      final r = next as ReviewingCardState;
      expect(r.interval, 10.0); // (4 + 0/2) * 2500/1000
      expect(r.factor, 2500);
    });

    test('Hard on time: interval * 1.2 floored at prev+1, factor -150', () {
      final next = applyToCardState(reviewing(), onTime, Rating.Hard);
      final r = next as ReviewingCardState;
      expect(r.interval, 5.0); // (4 + 0/4) * 1.2 = 4.8, floored at 4+1
      expect(r.factor, 2350);
    });

    test('Easy on time: doubled via EASY_BONUS, factor +150', () {
      final next = applyToCardState(reviewing(), onTime, Rating.Easy);
      final r = next as ReviewingCardState;
      expect(r.interval, 20.0); // ((4 + 0) * 2500/1000) * 2
      expect(r.factor, 2650);
    });

    test('reviewing late grows the Good interval by half the delay', () {
      // 2 days late: (4 + 2/2) * 2500/1000 = 12.5.
      final twoDaysLate = DateTime(2026, 1, 16, 3, 30);
      final next = applyToCardState(reviewing(), twoDaysLate, Rating.Good);
      expect((next as ReviewingCardState).interval, 12.5);
    });

    test('interval is capped at MAX_INTERVAL days', () {
      final next = applyToCardState(
          reviewing(interval: 300),
          DateTime(2026, 11, 6, 3, 30), // its due date (300 days later)
          Rating.Good);
      expect((next as ReviewingCardState).interval, 365.0);
    });
  });

  group('applyToLapsedCardState matrix', () {
    LapsedCardState lapsed({int consecutiveCorrect = 0}) => LapsedCardState(
        master: 'm',
        combination: combo01(),
        factor: 2300,
        lapses: 1,
        interval: 4.0,
        consecutiveCorrect: consecutiveCorrect,
        lastReviewed: t0);

    test('Easy requalifies immediately at 1 day, keeping factor/lapses', () {
      final next = applyToCardState(lapsed(), t0, Rating.Easy);
      expect(next, isA<ReviewingCardState>());
      final r = next as ReviewingCardState;
      expect(r.interval, 1.0);
      expect(r.factor, 2300);
      expect(r.lapses, 1);
    });

    test('Good after one correct requalifies at 4 days', () {
      final next = applyToCardState(lapsed(consecutiveCorrect: 1), t0,
          Rating.Good);
      expect(next, isA<ReviewingCardState>());
      expect((next as ReviewingCardState).interval, 4.0);
    });

    test('Good on a fresh lapse stays lapsed, counts one correct', () {
      final next = applyToCardState(lapsed(), t0, Rating.Good);
      expect(next, isA<LapsedCardState>());
      expect((next as LapsedCardState).consecutiveCorrect, 1);
    });

    test('Again stays lapsed and resets the count', () {
      final next =
          applyToCardState(lapsed(consecutiveCorrect: 1), t0, Rating.Again);
      expect(next, isA<LapsedCardState>());
      expect((next as LapsedCardState).consecutiveCorrect, 0);
    });

    test('CURRENT BEHAVIOR: Hard while lapsed counts toward requalifying', () {
      final next = applyToCardState(lapsed(), t0, Rating.Hard);
      expect(next, isA<LapsedCardState>());
      expect((next as LapsedCardState).consecutiveCorrect, 1);
    });
  });

  group('calculateDueDate goldens', () {
    test('adds ceil(interval) days, pins hour to 3, keeps minutes onward', () {
      final state = ReviewingCardState(
          master: 'm',
          combination: combo01(),
          factor: 2500,
          lapses: 0,
          interval: 4.4,
          lastReviewed: DateTime(2026, 1, 10, 8, 30, 12, 345, 678));
      expect(calculateDueDate(state),
          DateTime(2026, 1, 15, 3, 30, 12, 345, 678));
    });

    test('day overflow rolls into the next month', () {
      final state = ReviewingCardState(
          master: 'm',
          combination: combo01(),
          factor: 2500,
          lapses: 0,
          interval: 5.0,
          lastReviewed: DateTime(2026, 1, 30, 22, 45, 30));
      expect(calculateDueDate(state), DateTime(2026, 2, 4, 3, 45, 30));
    });

    test('null when never reviewed or no interval', () {
      expect(calculateDueDate(freshCard('m')), isNull);
      final noInterval = LearningCardState(
          master: 'm',
          combination: combo01(),
          consecutiveCorrect: 0,
          lastReviewed: t0);
      expect(calculateDueDate(noInterval), isNull);
    });
  });

  group('computeCardsSchedule bucketing', () {
    ReviewingCardState reviewingDue(DateTime lastReviewed) =>
        ReviewingCardState(
            master: 'm',
            combination: combo01(),
            factor: 2500,
            lapses: 0,
            interval: 4.0,
            lastReviewed: lastReviewed);

    test('reviewing cards split across later/due/overdue by now', () {
      // lastReviewed Jan 10 + interval 4 -> due Jan 14.
      final state = DRState({'a': reviewingDue(t0)});
      String bucketAt(DateTime now) {
        final s = computeCardsSchedule(state, now);
        if (s.later!.isNotEmpty) return 'later';
        if (s.due!.isNotEmpty) return 'due';
        if (s.overdue!.isNotEmpty) return 'overdue';
        return 'learning';
      }

      expect(bucketAt(DateTime(2026, 1, 13, 23, 0)), 'later');
      expect(bucketAt(DateTime(2026, 1, 14, 0, 1)), 'due');
      expect(bucketAt(DateTime(2026, 1, 15, 0, 1)), 'overdue');
    });

    test('learning and lapsed cards always land in learning', () {
      final state = DRState({
        'fresh': freshCard('fresh'),
        'lapsed': LapsedCardState(
            master: 'lapsed',
            combination: combo01(),
            factor: 2300,
            lapses: 1,
            interval: 4.0,
            consecutiveCorrect: 0,
            lastReviewed: t0),
      });
      final s = computeCardsSchedule(state, t0);
      expect(s.learning!.length, 2);
    });
  });

  group('pickMostDue selection order', () {
    test('learning bucket beats overdue and due', () {
      final dolphin = DolphinSR(now: () => DateTime(2026, 1, 20));
      dolphin.addMasters([
        Master(id: 'overdue', fields: const ['f', 'b'], combinations: [
          combo01()
        ]),
        Master(id: 'fresh', fields: const ['f', 'b'], combinations: [
          combo01()
        ]),
      ]);
      // Graduate 'overdue' so it becomes a reviewing card that is overdue
      // by Jan 20, while 'fresh' stays learning.
      dolphin.addReviews([reviewFor('overdue', t0, Rating.Easy)]);
      expect(dolphin.nextCard()!.master, 'fresh');
    });

    test('within learning: never-reviewed first, then oldest lastReviewed',
        () {
      final state = DRState({});
      for (final entry in {
        'oldest': DateTime(2026, 1, 1),
        'newest': DateTime(2026, 1, 5),
        'never': null,
      }.entries) {
        state.cardStates['${entry.key}#0@1'] = LearningCardState(
            master: entry.key,
            combination: combo01(),
            consecutiveCorrect: 0,
            lastReviewed: entry.value);
      }
      final schedule = computeCardsSchedule(state, DateTime(2026, 1, 20));
      expect(pickMostDue(schedule, state)!.id, 'never');

      state.cardStates.remove('never#0@1');
      final schedule2 = computeCardsSchedule(state, DateTime(2026, 1, 20));
      expect(pickMostDue(schedule2, state)!.id, 'oldest');
    });

    test('staggered timestamps define a stable draw order (the seed trick)',
        () {
      // This is how dictionarylib randomizes card order today: every card
      // gets a synthetic Again review at a distinct early timestamp, and
      // draws come out in timestamp order.
      final dolphin = DolphinSR(now: () => DateTime(2026, 1, 20));
      final ids = ['c', 'a', 'b'];
      dolphin.addMasters([
        for (final id in ids)
          Master(id: id, fields: const ['f', 'b'], combinations: [combo01()])
      ]);
      var ts = 1000000;
      dolphin.addReviews([
        for (final id in ids)
          reviewFor(id, DateTime.fromMillisecondsSinceEpoch(ts += 1000),
              Rating.Again)
      ]);
      expect(dolphin.nextCard()!.master, 'c');
    });

    test('ties break by insertion order', () {
      final state = DRState({});
      for (final id in ['zeta', 'alpha', 'mid']) {
        state.cardStates['$id#0@1'] = LearningCardState(
            master: id,
            combination: combo01(),
            consecutiveCorrect: 0,
            lastReviewed: null);
      }
      final schedule = computeCardsSchedule(state, DateTime(2026, 1, 20));
      expect(pickMostDue(schedule, state)!.id, 'zeta');
    });

    test('shuffleCardOrder with the same seed reproduces the same order',
        () {
      List<String> drawAll(DolphinSR d) {
        final out = <String>[];
        // Rate each served card Again "now" so it moves behind the
        // remaining fresh cards and every card gets served once.
        var ts = DateTime(2026, 1, 20);
        for (var i = 0; i < 6; i++) {
          final card = d.nextCard()!;
          out.add('${card.master}/${card.combination!.front!.first}');
          d.addReviews([
            Review(
                master: card.master,
                combination: card.combination,
                ts: ts = ts.add(const Duration(seconds: 1)),
                rating: Rating.Again)
          ]);
        }
        return out;
      }

      DolphinSR build(int seed) {
        final d = DolphinSR(now: () => DateTime(2026, 1, 20));
        d.addMasters([
          for (final id in ['a', 'b', 'c'])
            Master(id: id, fields: const [
              'f',
              'b'
            ], combinations: [
              const Combination(front: [0], back: [1]),
              const Combination(front: [1], back: [0]),
            ])
        ], shuffleCardOrder: true, random: math.Random(seed));
        return d;
      }

      final first = drawAll(build(42));
      final second = drawAll(build(42));
      expect(second, first);
      expect(first.toSet().length, 6, reason: 'every card served once');
    });

    test('empty schedule yields null', () {
      expect(pickMostDue(const CardsSchedule(later: [], due: [], overdue: [], learning: []), DRState(const {})), isNull);
    });
  });

  group('DolphinSR end-to-end', () {
    test('summary tracks cards across buckets; cardsLength counts cards', () {
      final dolphin = DolphinSR(now: () => DateTime(2026, 1, 10, 12));
      dolphin.addMasters([
        for (final id in ['a', 'b', 'c'])
          Master(
              id: id,
              fields: const ['f', 'b'],
              combinations: [
                const Combination(front: [0], back: [1]),
                const Combination(front: [1], back: [0]),
              ])
      ]);
      expect(dolphin.cardsLength(), 6);
      expect(dolphin.summary(),
          const SummaryStatics(later: 0, due: 0, overdue: 0, learning: 6));

      // Easy graduates one card at 1 day -> due Jan 11 -> 'later' now.
      dolphin.addReviews([reviewFor('a', t0, Rating.Easy)]);
      expect(dolphin.summary(),
          const SummaryStatics(later: 1, due: 0, overdue: 0, learning: 5));
    });

    test('duplicate master ids are rejected', () {
      final dolphin = DolphinSR();
      final master =
          Master(id: 'a', fields: const ['f', 'b'], combinations: [combo01()]);
      dolphin.addMasters([master]);
      expect(() => dolphin.addMasters([master]), throwsA(isA<DuplicateMasterException>()));
    });

    test('review for an unknown card throws', () {
      final dolphin = DolphinSR();
      expect(() => dolphin.addReviews([reviewFor('ghost', t0, Rating.Good)]),
          throwsA(isA<UnknownCardException>()));
    });

    test('out-of-order review throws', () {
      final dolphin = DolphinSR();
      dolphin.addMasters([
        Master(id: 'a', fields: const ['f', 'b'], combinations: [combo01()])
      ]);
      dolphin.addReviews([reviewFor('a', t0, Rating.Good)]);
      expect(
          () => dolphin.addReviews(
              [reviewFor('a', t0.subtract(const Duration(days: 1)), Rating.Good)]),
          throwsA(isA<OutOfOrderReviewException>()));
    });
  });

  group('OutOfOrderReviewPolicy.skip', () {
    test('drops only the offending reviews, counts them, applies the rest',
        () {
      final dolphin = DolphinSR(
          now: () => DateTime(2026, 1, 20),
          outOfOrderReviewPolicy: OutOfOrderReviewPolicy.skip);
      dolphin.addMasters([
        for (final id in ['a', 'b'])
          Master(id: id, fields: const ['f', 'b'], combinations: [combo01()])
      ]);
      dolphin.addReviews([
        reviewFor('a', DateTime(2026, 1, 5), Rating.Good),
        // Out of order for 'a' — must be dropped without aborting the batch.
        reviewFor('a', DateTime(2026, 1, 3), Rating.Again),
        reviewFor('b', DateTime(2026, 1, 4), Rating.Good),
      ]);
      expect(dolphin.skippedOutOfOrderReviews, 1);
      final byMaster = {
        for (final c in dolphin.getAllCardState()) c.master: c.lastReviewed
      };
      // 'a' keeps the in-order review; the dropped Again didn't regress it.
      expect(byMaster['a'], DateTime(2026, 1, 5));
      // 'b', after the bad review, was still applied.
      expect(byMaster['b'], DateTime(2026, 1, 4));
    });
  });

  group('incremental schedule cache', () {
    test('warm-cache updates match a cold full recompute', () {
      DolphinSR build() {
        final d = DolphinSR(now: () => DateTime(2026, 1, 20));
        d.addMasters([
          for (final id in ['a', 'b', 'c'])
            Master(id: id, fields: const ['f', 'b'], combinations: [combo01()])
        ]);
        return d;
      }

      final reviews = [
        reviewFor('a', t0, Rating.Easy), // graduates, due Jan 11
        reviewFor('b', t0, Rating.Good), // stays learning
        reviewFor('a', DateTime(2026, 1, 11, 4), Rating.Again), // lapses
      ];

      // Warm the cache before and between every single-review add, so each
      // add goes through the incremental card-move path.
      final incremental = build();
      incremental.summary();
      for (final r in reviews) {
        incremental.addReviews([r]);
        incremental.summary();
      }

      final cold = build()..addReviews(reviews);
      expect(incremental.summary(), cold.summary());
      expect(incremental.nextCard(), cold.nextCard());
    });
  });

  group('clock handling', () {
    test('schedule follows the clock across days without new reviews', () {
      var fakeNow = DateTime(2026, 1, 10, 12);
      final dolphin = DolphinSR(now: () => fakeNow);
      dolphin.addMasters([
        Master(id: 'a', fields: const ['f', 'b'], combinations: [combo01()])
      ]);
      // Easy on a fresh card graduates at 1 day -> due Jan 11.
      dolphin.addReviews([reviewFor('a', t0, Rating.Easy)]);
      expect(dolphin.summary().later, 1);

      fakeNow = DateTime(2026, 1, 11, 12);
      expect(dolphin.summary().due, 1);

      fakeNow = DateTime(2026, 1, 13, 12);
      expect(dolphin.summary().overdue, 1);
    });
  });
}
