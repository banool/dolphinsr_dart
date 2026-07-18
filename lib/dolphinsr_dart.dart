library dolphinsr_dart;

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

  void _addMaster(Master master) {
    if (_masters.containsKey(master.id)) {
      throw DuplicateMasterException(master.id);
    }

    for (final combination in master.combinations!) {
      final cardId =
          CardId.fromCombination(combination: combination, master: master.id);

      _state!.cardStates[cardId.uniqueId] =
          makeInitialCardState(id: master.id, combination: combination);
    }

    _masters[master.id] = master;
  }

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

  void addMasters(List<Master> masters) {
    for (var i = 0; i < masters.length; i++) {
      final master = masters[i];
      _addMaster(master);
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

  int cardReviewedTodayLength() {
    return cardReviewedAtDateLength(DateTime.now());
  }

  int cardReviewedAtDateLength(DateTime date) {
    return _state!.cardStates.values.where((st) {
      final dueDate = calculateDueDate(st!);
      return dueDate == null ||
          dueDate.year == date.year &&
              dueDate.month == date.month &&
              dueDate.day == date.day;
    }).length;
  }

  int cardsLength() {
    return _state!.cardStates.length;
  }
}
