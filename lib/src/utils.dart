import 'dart:math' as math;
import './exceptions.dart';
import './models.dart';

List<Review> addReview(List<Review> reviews, Review review) {
  if (reviews.isEmpty) {
    return <Review>[review];
  }
  var i = reviews.length - 1;
  for (; i >= 0; i -= 1) {
    if (reviews[i].ts!.isBefore(review.ts!) ||
        reviews[i].ts!.isAtSameMomentAs(review.ts!)) {
      break;
    }
  }

  final newReviews = reviews.sublist(0);
  newReviews.insert(i + 1, review);

  return newReviews;
}

// constants from Anki defaults
const double INITIAL_FACTOR = 2500;
const double INITIAL_DAYS_WITHOUT_JUMP = 4;
const double INITIAL_DAYS_WITH_JUMP = 1;

const int EASY_BONUS = 2;
const int MAX_INTERVAL = 365;
const int MIN_FACTOR = 0;
const int MAX_FACTOR = 2147483647;

CardState applyToLearningCardState(
    LearningCardState prev, DateTime? ts, Rating rating) {
  switch (rating) {
    case Rating.Again:
    case Rating.Hard:
      return LearningCardState(
          master: prev.master,
          combination: prev.combination,
          consecutiveCorrect: 0,
          lastReviewed: ts);
    case Rating.Good:
      if (prev.consecutiveCorrect! < 1) {
        return LearningCardState(
            master: prev.master,
            combination: prev.combination,
            consecutiveCorrect: prev.consecutiveCorrect! + 1,
            lastReviewed: ts);
      }
      return _graduateFromLearning(prev, ts);
    case Rating.Easy:
      return _graduateFromLearning(prev, ts);
  }
}

ReviewingCardState _graduateFromLearning(LearningCardState prev, DateTime? ts) {
  final interval = prev.consecutiveCorrect! > 0
      ? INITIAL_DAYS_WITHOUT_JUMP
      : INITIAL_DAYS_WITH_JUMP;
  return ReviewingCardState(
      master: prev.master,
      combination: prev.combination,
      factor: INITIAL_FACTOR,
      lapses: 0,
      interval: interval.toDouble(),
      lastReviewed: ts);
}

double constrainWithin(double min, num max, double n) {
  return math.max(math.min(n, max.toDouble()), min);
}

DateTime? calculateDueDate(CardState state) {
  final result = state.lastReviewed;
  if (result == null || state.interval == null) return null;

  const newHour = 3;
  final newDay = result.day + state.interval!.ceil();
  var newResult = result.toLocal();
  newResult = DateTime(result.year, result.month, newDay, newHour,
      result.minute, result.second, result.millisecond, result.microsecond);

  return newResult;
}

String computeScheduleFromCardState(CardState state, DateTime? now) {
  if (state.mode == 'lapsed' || state.mode == 'learning') {
    return 'learning';
  } else if (state.mode == 'reviewing') {
    final diff = dateDiffInDays(calculateDueDate(state)!, now!);
    if (diff < 0) {
      return 'later';
    } else if (diff >= 0 && diff < 1) {
      return 'due';
    } else if (diff >= 1) {
      return 'overdue';
    }
  }

  throw Exception('Issue with mode and calculation of a cardState');
}

/// The next card to serve: the highest-priority non-empty bucket
/// (learning, then overdue, then due — 'later' cards are never served),
/// and within it the card least recently reviewed, with never-reviewed
/// cards first and the uniqueId as a deterministic tie-break. A single
/// O(n) scan: this runs on every nextCard() over buckets that can hold
/// tens of thousands of cards, so no copying or sorting.
CardId? pickMostDue(CardsSchedule? s, DRState? state) {
  for (final key in const ['learning', 'overdue', 'due']) {
    final bucket = s!.getPropertyValue(key)!;
    if (bucket.isEmpty) {
      continue;
    }
    var best = bucket.first;
    var bestTs = state!.cardStates[best.uniqueId]!.lastReviewed;
    for (var i = 1; i < bucket.length; i++) {
      final candidate = bucket[i];
      final candidateTs = state.cardStates[candidate.uniqueId]!.lastReviewed;
      if (_isMoreDue(candidate, candidateTs, best, bestTs)) {
        best = candidate;
        bestTs = candidateTs;
      }
    }
    return best;
  }
  return null;
}

bool _isMoreDue(CardId a, DateTime? aTs, CardId b, DateTime? bTs) {
  if (aTs == null || bTs == null) {
    if ((aTs == null) != (bTs == null)) {
      return aTs == null;
    }
  } else if (!aTs.isAtSameMomentAs(bTs)) {
    return aTs.isBefore(bTs);
  }
  return a.uniqueId!.compareTo(b.uniqueId!) < 0;
}

CardsSchedule computeCardsSchedule(DRState state, DateTime? now) {
  final s = CardsSchedule(
      later: <CardId>[],
      due: <CardId>[],
      overdue: <CardId>[],
      learning: <CardId>[]);

  for (final cardStateKey in state.cardStates.keys) {
    final cardState = state.cardStates[cardStateKey]!;

    final calculatedSchedule = computeScheduleFromCardState(cardState, now);

    s.getPropertyValue(calculatedSchedule)!.add(CardId.fromState(cardState));
  }

  return s;
}

double dateDiffInDays(DateTime a, DateTime b) {
  // adapted from http://stackoverflow.com/a/15289883/251162
  const MS_PER_DAY = 1000 * 60 * 60 * 24;

  // Disstate the time and time-zone information.

  final utc1 = DateTime.utc(a.year, a.month, a.day);

  final utc2 = DateTime.utc(b.year, b.month, b.day);

  return (utc2.difference(utc1)).inMilliseconds / MS_PER_DAY;
}

/// Days between the card's due date and when it was actually reviewed:
/// positive when the review happened after the due date. The interval
/// formulas grow the next interval by a share of this (you remembered the
/// card despite the extra delay), matching the upstream algorithm.
double calculateDaysLate(ReviewingCardState state, DateTime actual) {
  final expected = calculateDueDate(state)!;

  final daysLate = dateDiffInDays(expected, actual);

  return daysLate;
}

CardState applyToReviewingCardState(
    ReviewingCardState prev, DateTime? ts, Rating? rating) {
  if (rating == Rating.Again) {
    return LapsedCardState(
        master: prev.master,
        combination: prev.combination,
        consecutiveCorrect: 0,
        factor: constrainWithin(
            MIN_FACTOR.toDouble(), MAX_FACTOR, prev.factor!.toDouble() - 200),
        lapses: prev.lapses! + 1,
        interval: prev.interval,
        lastReviewed: ts);
  }

  final factorAdj = rating == Rating.Hard
      ? -150
      : rating == Rating.Good
          ? 0
          : rating == Rating.Easy
              ? 150
              : double.nan;

  final daysLate = calculateDaysLate(prev, ts!);

  final fact = rating == Rating.Hard
      ? (prev.interval! + (daysLate / 4)) * 1.2
      : rating == Rating.Good
          ? ((prev.interval! + (daysLate / 2)) * prev.factor!) / 1000
          : rating == Rating.Easy
              ? (((prev.interval! + daysLate) * prev.factor!) / 1000) *
                  EASY_BONUS
              : double.nan;
  final ival = constrainWithin(prev.interval! + 1, MAX_INTERVAL, fact);

  return ReviewingCardState(
      master: prev.master,
      combination: prev.combination,
      factor: constrainWithin(
          MIN_FACTOR.toDouble(), MAX_FACTOR, prev.factor! + factorAdj),
      lapses: prev.lapses,
      interval: ival,
      lastReviewed: ts);
}

CardState applyToLapsedCardState(
    LapsedCardState prev, DateTime? ts, Rating? rating) {
  if (rating == Rating.Easy ||
      ((rating == Rating.Easy || rating == Rating.Good) &&
          prev.consecutiveCorrect! > 0)) {
    return ReviewingCardState(
      master: prev.master,
      combination: prev.combination,
      factor: prev.factor,
      lapses: prev.lapses,
      interval: prev.consecutiveCorrect! > 0
          ? INITIAL_DAYS_WITHOUT_JUMP
          : INITIAL_DAYS_WITH_JUMP,
      lastReviewed: ts,
    );
  }

  return LapsedCardState(
      master: prev.master,
      combination: prev.combination,
      factor: prev.factor,
      lapses: prev.lapses,
      interval: prev.interval,
      lastReviewed: ts,
      consecutiveCorrect:
          rating == Rating.Again ? 0 : prev.consecutiveCorrect! + 1);
}

CardState applyToCardState(CardState prev, DateTime? ts, Rating? rating) {
  if (prev.lastReviewed != null && prev.lastReviewed!.isAfter(ts!)) {
    throw OutOfOrderReviewException(prev.master, ts, prev.lastReviewed);
  }

  if (prev.mode == 'learning') {
    return applyToLearningCardState(prev as LearningCardState, ts, rating!);
  } else if (prev.mode == 'reviewing') {
    return applyToReviewingCardState(prev as ReviewingCardState, ts, rating);
  } else if (prev.mode == 'lapsed') {
    return applyToLapsedCardState(prev as LapsedCardState, ts, rating);
  }

  throw Exception('Card mode is incorrect');
}

void applyReview(DRState state, Review review) {
  final cardId = CardId.fromReview(review);

  final cardState = state.cardStates[cardId.uniqueId];

  if (cardState == null) {
    throw UnknownCardException(review.master);
  }

  state.cardStates[cardId.uniqueId] =
      applyToCardState(cardState, review.ts, review.rating);
}

String getCardIdFromCardState(CardState cardState) {
  final id = cardState.master;
  final frontJoin = cardState.combination!.front!.join(',');
  final backJoin = cardState.combination!.back!.join(',');
  return '$id#$frontJoin@$backJoin';
}

DRState makeEmptyState() {
  return DRState(<String, CardState>{});
}

LearningCardState makeInitialCardState({String? id, Combination? combination}) {
  return LearningCardState(
      master: id,
      combination: combination,
      lastReviewed: null,
      consecutiveCorrect: 0);
}
