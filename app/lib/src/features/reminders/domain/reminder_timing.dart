/// The largest callback delta that can contribute to a real-time reminder.
///
/// Larger deltas normally mean the process or machine was suspended. They are
/// deliberately discarded so timers never catch up after a sleep/freeze gap.
const reminderCallbackGapTolerance = Duration(milliseconds: 2500);

/// Whether [delta] represents eligible elapsed time for reminder engines.
bool reminderDeltaContributes(Duration delta, {bool isGap = false}) {
  return !isGap &&
      delta > Duration.zero &&
      delta <= reminderCallbackGapTolerance;
}
