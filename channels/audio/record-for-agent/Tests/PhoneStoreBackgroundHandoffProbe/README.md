# Phone Store background handoff probe

Run `python3 Tests/PhoneStoreBackgroundHandoffProbe/verify.py` from the repository.

The probe extracts `PhoneStore.performBackgroundSync` and
`discoverBackgroundSources` verbatim into a MainActor property shell. It also
copies the unchanged production cancellation class. In-memory repository,
Watch-maintenance, cloud-worker and processing-registration adapters exercise
the real orchestration without devices, real recordings, audio APIs, network
or an application container.

Scenarios verify that both cloud ledger turns begin before full source metadata
or receiver preparation can hold the shared repository lock; newly durable
receipt metadata still feeds all queues after those bounded turns; iCloud provider pending preserves fallback despite completed local
export; unchanged settled metadata does not self-invalidate the scheduling
generation; cancellation before or during the metadata read and metadata read
failure cannot claim success; parent cancellation before the callback cannot
start cloud preparation. Processing registrations
must be released in each branch. Cold restoration of historical metadata must
still feed the workers without falsely advancing the new-external-work generation.

The proof binds before/after source hashes and the exact prepared source. These
are orchestration tests with controlled workers, not proof that iOS granted a
background wake, that real cloud upload succeeded, or that a recording's content
was validated.
