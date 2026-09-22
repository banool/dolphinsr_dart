/// A spaced-repetition scheduling algorithm for Dart, based on Anki's
/// variant of the SM-2 algorithm. Use it to build flashcard and review
/// systems for Flutter, web, or server apps.
///
/// The entry point is [DolphinSR]: register cards with
/// [DolphinSR.addMasters], feed answers back with [DolphinSR.addReviews],
/// and ask what to show next with [DolphinSR.nextCard].
library;

import 'dart:math' as math;

import './src/exceptions.dart';
import './src/models.dart';
import './src/utils.dart';
export './src/exceptions.dart';
export './src/models.dart';

class DolphinSR {
  DolphinSR(
      {DateTime Function()? now,
      this.outOfOrderReviewPolicy = OutOfOrderReviewPolicy.throwError})
      : _now = now ?? DateTime.now {
    _state = makeEmptyState();
    _masters = <String?, Master>{};
  }

  DRState? _state;
  late Map<String?, Master> _masters;
  CardsSchedule? _cachedCardsSchedule;

  /// When the cached schedule was computed. Bucket membership (later/due/
  /// overdue) changes at calendar-day granularity, so the cache is only
  /// valid within the day it was computed on.
  DateTime? _cachedScheduleAt;

  /// Which bucket of [_cachedCardsSchedule] each card currently sits in
  /// (by uniqueId), so a single review can move its card between buckets
  /// without recomputing the whole schedule.
  final Map<String, String> _cachedBucketOf = <String, String>{};

  /// The clock. Injectable for tests and long-lived instances; defaults to
  /// the real time so a session that spans midnight reschedules correctly.
  final DateTime Function() _now;

  final OutOfOrderReviewPolicy outOfOrderReviewPolicy;

  /// How many reviews [addReviews] has dropped under
  /// [OutOfOrderReviewPolicy.skip], for callers that want to log it.
  int get skippedOutOfOrderReviews => _skippedOutOfOrderReviews;
  int _skippedOutOfOrderReviews = 0;

  bool cardExistInMaster(String id) {
    return _masters.containsKey(id);
  }

  void removeFromMaster(String masterId) {
    final master = _masters[masterId]!;

    for (final combination in master.combinations!) {
      final cardId =
          CardId.fromCombination(combination: combination, master: master.id);
      _state!.cardStates.remove(cardId.uniqueId);
    }
    _invalidateSchedule();

    _masters.remove(masterId);
  }

  /// Register masters and create a fresh card per (master, combination).
  ///
  /// Card states live in an insertion-ordered map and [pickMostDue] breaks
  /// ties by position, so the insertion order here IS the order fresh cards
  /// are served in. With [shuffleCardOrder] the cards (not just the
  /// masters) are shuffled before insertion — pass a seeded [random] to get
  /// the same order back when rebuilding an instance mid-session. This
  /// replaces the old trick of seeding every card with a synthetic review
  /// at a staggered timestamp just to randomize the draw order.
  void addMasters(List<Master> masters,
      {bool shuffleCardOrder = false, math.Random? random}) {
    final cards = <(Master, Combination)>[];
    for (final master in masters) {
      if (_masters.containsKey(master.id)) {
        throw DuplicateMasterException(master.id);
      }
      _masters[master.id] = master;
      for (final combination in master.combinations!) {
        cards.add((master, combination));
      }
    }
    if (shuffleCardOrder) {
      cards.shuffle(random ?? math.Random());
    }
    for (final (master, combination) in cards) {
      final cardId =
          CardId.fromCombination(combination: combination, master: master.id);
      _state!.cardStates[cardId.uniqueId] =
          makeInitialCardState(id: master.id, combination: combination);
    }
    _invalidateSchedule();
  }

  /// Widen an already-registered master with more combinations, creating a
  /// fresh card for each one that has no card state yet.
  ///
  /// A deck that gains a card type, or a persisted review history replayed
  /// against a master set rebuilt without that card type, produces reviews for
  /// a (master, combination) pair [addMasters] never created a card for —
  /// [addReviews] then throws [UnknownCardException] for every one of them.
  /// This is the supported way to close that gap: [addMasters] rejects a known
  /// id with [DuplicateMasterException], and [removeFromMaster] would discard
  /// the master's existing card states along with their schedules.
  ///
  /// Combinations the master already has are ignored and existing card states
  /// are never replaced, so calling this repeatedly is safe. New cards are
  /// appended, so they are served after the cards already registered (see
  /// [addMasters] on why insertion order matters).
  ///
  /// Throws [UnknownMasterException] if no master is registered under
  /// [masterId]; use [addMasters] for a master that does not exist yet.
  void addCombinations(String masterId, List<Combination> combinations) {
    final master = _masters[masterId];
    if (master == null) {
      throw UnknownMasterException(masterId);
    }

    final existing = master.combinations ?? const <Combination>[];
    final added = <Combination>[];
    for (final combination in combinations) {
      if (!existing.contains(combination) && !added.contains(combination)) {
        added.add(combination);
      }
    }
    if (added.isEmpty) {
      return;
    }

    _masters[masterId] = Master(
        id: master.id,
        fields: master.fields,
        combinations: [...existing, ...added]);

    for (final combination in added) {
      final cardId =
          CardId.fromCombination(combination: combination, master: masterId);
      _state!.cardStates.putIfAbsent(cardId.uniqueId,
          () => makeInitialCardState(id: masterId, combination: combination));
    }
    _invalidateSchedule();
  }

  void addReviews(List<Review> reviews) {
    for (final review in reviews) {
      try {
        applyReview(_state!, review);
        _moveCardInCachedSchedule(review);
      } on OutOfOrderReviewException {
        if (outOfOrderReviewPolicy == OutOfOrderReviewPolicy.throwError) {
          _invalidateSchedule();
          rethrow;
        }
        _skippedOutOfOrderReviews++;
      }
    }
  }

  /// A review changes the bucket of exactly one card, so keep the cached
  /// schedule alive by moving that card rather than recomputing all cards
  /// on the next read (the recompute is O(cards) and runs after every
  /// answered card in a session otherwise). No-op when nothing is cached.
  void _moveCardInCachedSchedule(Review review) {
    final cached = _cachedCardsSchedule;
    if (cached == null) {
      return;
    }
    final uniqueId = CardId.fromReview(review).uniqueId!;
    final oldBucket = _cachedBucketOf[uniqueId];
    if (oldBucket != null) {
      cached.getPropertyValue(oldBucket)!.remove(CardId.fromReview(review));
    }
    final newState = _state!.cardStates[uniqueId]!;
    // Bucket as of the cache's own day; if the day has rolled since, the
    // next read rebuilds the whole schedule anyway.
    final newBucket = computeScheduleFromCardState(newState, _cachedScheduleAt);
    cached.getPropertyValue(newBucket)!.add(CardId.fromState(newState));
    _cachedBucketOf[uniqueId] = newBucket;
  }

  void _invalidateSchedule() {
    _cachedCardsSchedule = null;
    _cachedScheduleAt = null;
    _cachedBucketOf.clear();
  }

  CardsSchedule _getCardsSchedule() {
    final nowValue = _now();
    if (_cachedCardsSchedule != null &&
        _cachedScheduleAt != null &&
        _cachedScheduleAt!.year == nowValue.year &&
        _cachedScheduleAt!.month == nowValue.month &&
        _cachedScheduleAt!.day == nowValue.day) {
      return _cachedCardsSchedule!;
    }

    final schedule = computeCardsSchedule(_state!, nowValue);
    _cachedCardsSchedule = schedule;
    _cachedScheduleAt = nowValue;
    _cachedBucketOf.clear();
    for (final bucket in const ['later', 'due', 'overdue', 'learning']) {
      for (final cardId in schedule.getPropertyValue(bucket)!) {
        _cachedBucketOf[cardId.uniqueId!] = bucket;
      }
    }
    return _cachedCardsSchedule!;
  }

  CardId? _nextCardId() {
    final cardSchedule = _getCardsSchedule();
    return pickMostDue(cardSchedule, _state);
  }

  DRCard? _getCard(CardId cardId) {
    final master = _masters[cardId.id];

    final cardState = _state!.cardStates[cardId.uniqueId];
    if (master == null) {
      return null;
    }

    final frontField = cardState!.combination!.front!
        .map((int i) => master.fields![i])
        .toList();
    final backFields =
        cardState.combination!.back!.map((int i) => master.fields![i]).toList();

    final dueDate = calculateDueDate(cardState);
    final card = DRCard(
        master: cardState.master,
        combination: cardState.combination,
        front: frontField,
        back: backFields,
        lastReviewed: cardState.lastReviewed,
        dueDate: dueDate);

    return card;
  }

  List<DRCard> getAllCardState() {
    return _state!.cardStates.values.map((cardState) {
      final frontField = cardState!.combination!.front!
          .map((int i) => _masters[cardState.master]!.fields![i])
          .toList();
      final backFields = cardState.combination!.back!
          .map((int i) => _masters[cardState.master]!.fields![i])
          .toList();

      final dueDate = calculateDueDate(cardState);
      final card = DRCard(
          master: cardState.master,
          combination: cardState.combination,
          front: frontField,
          back: backFields,
          lastReviewed: cardState.lastReviewed,
          dueDate: dueDate);

      return card;
    }).toList();
  }

  DRCard? nextCard() {
    final nextCardId = _nextCardId();
    if (nextCardId == null) {
      return null;
    }
    return _getCard(nextCardId);
  }

  SummaryStatics summary() {
    final s = _getCardsSchedule();
    final summary = SummaryStatics(
        later: s.later!.length,
        due: s.due!.length,
        overdue: s.overdue!.length,
        learning: s.learning!.length);

    return summary;
  }

  int cardsLength() {
    return _state!.cardStates.length;
  }
}
