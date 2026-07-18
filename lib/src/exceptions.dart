/// Typed exceptions (instead of bare string throws) so callers can catch
/// specific failure modes, plus the policy knob for how out-of-order
/// reviews are handled.

/// A review's timestamp precedes its card's current lastReviewed. Reviews
/// must be applied in per-card chronological order; histories written with
/// a misbehaving device clock can violate that.
class OutOfOrderReviewException implements Exception {
  const OutOfOrderReviewException(this.master, this.reviewTs, this.lastReviewed);

  final String? master;
  final DateTime? reviewTs;
  final DateTime? lastReviewed;

  @override
  String toString() =>
      'OutOfOrderReviewException: review of $master at $reviewTs precedes '
      'lastReviewed $lastReviewed';
}

/// A review references a master/combination that no card was created for.
class UnknownCardException implements Exception {
  const UnknownCardException(this.master);

  final String? master;

  @override
  String toString() => 'UnknownCardException: no card for master $master';
}

/// addMasters received a master id that is already registered.
class DuplicateMasterException implements Exception {
  const DuplicateMasterException(this.master);

  final String? master;

  @override
  String toString() => 'DuplicateMasterException: master $master already added';
}

/// What [DolphinSR.addReviews] does with an out-of-order review.
enum OutOfOrderReviewPolicy {
  /// Throw [OutOfOrderReviewException] (the default, and the historical
  /// behavior).
  throwError,

  /// Silently drop the offending review, keep applying the rest, and count
  /// it in [DolphinSR.skippedOutOfOrderReviews]. The right choice for
  /// replaying persisted histories where one bad timestamp must not take
  /// down the whole session.
  skip,
}
