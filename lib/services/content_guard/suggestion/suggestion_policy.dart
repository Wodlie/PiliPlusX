/// Thresholds and cooldowns of the blacklist suggestion machine.
///
/// Every value here is a *policy* decision the user could one day change, so
/// none of them is hardcoded into the algorithm: the machine reads them from this
/// object, and the checks drive the machine by constructing different ones.
///
/// Pure data. No clock, no storage, no Flutter — a policy cannot make something
/// happen, it only tells the machine how far it may go.
library;

/// Stable reason codes a suggestion carries when it becomes visible or is
/// invalidated. Never localised; the UI maps them to text.
abstract final class SuggestionReasonCodes {
  /// The author crossed the counting threshold inside the window.
  static const String thresholdReached = 'suggestion.threshold_reached';

  /// The author's count fell below the threshold after corrections.
  static const String thresholdLost = 'suggestion.threshold_lost';

  /// The user rejected this author's suggestion before.
  static const String previouslyRejected = 'suggestion.previously_rejected';

  /// The suggestion is inside its snooze cooldown.
  static const String snoozed = 'suggestion.snoozed';

  /// The author is manually blacklisted already.
  static const String alreadyBlacklisted = 'suggestion.already_blacklisted';
}

/// Configuration of one suggestion machine.
final class SuggestionPolicy {
  const SuggestionPolicy({
    this.threshold = 2,
    this.windowDays = 30,
    this.snoozeCooldownMs = const Duration(days: 7),
    this.snoozeRepeatLimit = 3,
  });

  /// How many attributable violations make an author a candidate.
  ///
  /// Two, not one: a single flagged comment is far more often a filter mistake
  /// than a pattern, and a suggestion to block somebody off one hit is the most
  /// expensive mistake this subsystem can make.
  final int threshold;

  /// Window [threshold] is measured over, in days.
  final int windowDays;

  /// How long a snoozed suggestion stays out of the way.
  final Duration snoozeCooldownMs;

  /// How many times the same author may be snoozed before the machine treats it
  /// as a soft rejection.
  ///
  /// Snooze and reject stay distinct states — a soft rejection still expires
  /// after the cooldown, a hard rejection does not — but an author the user has
  /// waved away five times should not keep coming back on a timer.
  final int snoozeRepeatLimit;

  SuggestionPolicy copyWith({
    int? threshold,
    int? windowDays,
    Duration? snoozeCooldownMs,
    int? snoozeRepeatLimit,
  }) => SuggestionPolicy(
    threshold: threshold ?? this.threshold,
    windowDays: windowDays ?? this.windowDays,
    snoozeCooldownMs: snoozeCooldownMs ?? this.snoozeCooldownMs,
    snoozeRepeatLimit: snoozeRepeatLimit ?? this.snoozeRepeatLimit,
  );

  @override
  String toString() =>
      'SuggestionPolicy(threshold: $threshold, windowDays: $windowDays, '
      'cooldownMs: ${snoozeCooldownMs.inMilliseconds})';
}
