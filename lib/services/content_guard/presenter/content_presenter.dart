/// Turns a composed decision into the row state a list renders.
///
/// The presenter is deliberately tiny: it maps the composer's vocabulary onto
/// [ContentPresentation] and stamps the generation, so a late async result can be
/// recognised and dropped (plan-core section 9). It holds no state, reads no
/// clock and never removes a row — hidden content is still a row, only a
/// placeholder one, because deleting the element would lose the anchor a
/// restore needs and shift everything below it.
library;

import 'package:PiliPlus/services/content_guard/decision/decision_composer.dart';
import 'package:PiliPlus/services/content_guard/model/content_presentation.dart';
import 'package:PiliPlus/services/content_guard/model/guard_content.dart';

/// Stateless mapper from [DecisionComposerOutput] to [ContentPresentation].
final class ContentPresenter {
  const ContentPresenter();

  /// Presentation of [decision] for [contentId] in list revision [generation].
  ///
  /// [suggestionId] is recorded verbatim: the presenter never invents or looks
  /// up an anchor, it only carries the one the caller is currently showing.
  ContentPresentation present({
    required DecisionComposerOutput decision,
    required String contentId,
    required int generation,
    String? suggestionId,
  }) => ContentPresentation(
    contentId: contentId,
    state: decision.presentationState,
    recoverable: decision.recoverable,
    isPlaceholder: decision.presentationState.isPlaceholder,
    reasonCodes: decision.violationReasonCodes,
    tags: decision.tags,
    maskedMediaIds: decision.presentationState == PresenterState.masked
        ? decision.maskedMediaIds
        : const <String>{},
    generation: generation,
    explanation: decision.explanation,
    suggestionId: suggestionId,
  );

  /// Presentation of [decision] for [content], taking the content id from it.
  ContentPresentation presentContent({
    required GuardContent content,
    required DecisionComposerOutput decision,
    required int generation,
    String? suggestionId,
  }) => present(
    decision: decision,
    contentId: content.contentId,
    generation: generation,
    suggestionId: suggestionId,
  );

  /// The row to show before any decision exists.
  ///
  /// A pending row is a placeholder but is not recoverable: there is nothing to
  /// restore yet, and the decision is expected to arrive or be retried.
  ContentPresentation pending({
    required String contentId,
    required int generation,
  }) => ContentPresentation.pending(
    contentId: contentId,
    generation: generation,
  );

  /// Whether [candidate] must be discarded because [stored] is newer.
  ///
  /// The write-back guard: completion order is never list order, so a result
  /// computed for an older list revision is dropped instead of overwriting the
  /// row the user is looking at.
  static bool isStale({
    required ContentPresentation candidate,
    required ContentPresentation? stored,
  }) => stored != null && candidate.generation < stored.generation;
}
