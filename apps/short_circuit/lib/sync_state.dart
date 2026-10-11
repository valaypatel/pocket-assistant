part of 'main.dart';

/// What a sync is doing, for screens that are not the home page (a note's own page shows it).
/// The home page publishes it after each build; [syncUiState] holds the latest.
class SyncUiState {
  const SyncUiState({this.active = false, this.progress, this.error});

  /// A sync is asked for or running.
  final bool active;

  /// Percent of everything being sent, once it is known.
  final int? progress;

  /// Why the last sync did not finish, if it did not.
  final String? error;

  @override
  bool operator ==(Object other) =>
      other is SyncUiState &&
      other.active == active &&
      other.progress == progress &&
      other.error == error;

  @override
  int get hashCode => Object.hash(active, progress, error);
}

final ValueNotifier<SyncUiState> syncUiState = ValueNotifier(
  const SyncUiState(),
);

extension _SyncUi on _CircuitHomePageState {
  void _publishSyncUi() {
    final next = SyncUiState(
      active: _syncActive || _syncingNoteId != null,
      progress: _syncProgress,
      error: _syncError,
    );
    if (next == syncUiState.value) return;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => syncUiState.value = next,
    );
  }
}
