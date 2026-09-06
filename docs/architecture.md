# Architecture and verification

Lodge keeps AppKit, SwiftUI, and SwiftData. The services below separate stored
history from popup state and expensive content processing.

| Component | Responsibility |
| --- | --- |
| `Clipboard` | Poll the pasteboard and capture a consistent data snapshot. |
| `ContentProcessor` | Compute content hashes, text, counts, and search metadata on a worker task. |
| `HistoryService` | Apply duplicate rules, edits, pins, sorting, and history limits. |
| `HistoryRepository` | Save each operation once and restore state after a failed save. |
| `History` | Publish saved history, manage task lifetimes, and reject stale search results. |
| `SearchEngine` | Search value snapshots without access to SwiftData models. |
| `ImageProcessingService` and `OCRService` | Decode thumbnails and limit active OCR work. |
| `AppState` | Coordinate selection, popup behavior, and clipboard actions. |

## Storage

All model changes go through `HistoryRepository`. Autosave is disabled. Insert,
duplicate update, pruning, and deletion each use one save. The popup receives
new history only after the save succeeds. On failure, the repository rolls back
the context and restores model values that SwiftData can keep in its cache.

A duplicate keeps its UUID, content rows, pin, and alias. Its copy count and
last-copy date change. The service then sorts the list again. Content digests
are checked before subset matching. Content replacement deletes the old rows.

The default data limit is 512 MiB. It counts raw data, extracted and normalized
text, OCR text, and the text preview. SQLite files and indexes can use additional
space. The oldest unpinned items are removed first. Pinned items remain when the
limit is reduced. An item that cannot fit with the retained pins is rejected.
Edits, OCR updates, and pin removal are rejected if retention would remove the
updated item. This check runs before content rows or metadata change. A rejected
pin removal keeps the pin and shows a notice about the history limit.

Existing stores receive new metadata one item at a time. The service also
repairs duplicate UUID defaults and deletes orphaned content rows. Migration
tests open a store written with the previous schema. If the persistent store
cannot open, the popup shows a persistent notice about temporary storage.

## Processing and task limits

The pasteboard must be read on the main actor. Hashing, text extraction, word
counts, image file reads, decoding, and searches run outside the main actor.
SwiftData fetches and saves remain on the main actor. Large saves can still
cause delays and must be included in future performance checks.

Copies are processed in order. Pending raw data is limited to 200 MiB. Clearing
history cancels pending copies. Search starts without a fixed timer delay. A
content revision and request generation prevent old results from replacing a
new query. The result cache holds at most 20 queries for one revision.

Search includes full extracted text. The detail panel shows at most 5,000
characters and provides a **View full text** action. HTML extraction uses
SwiftSoup and does not load remote images or styles.

Image previews use a 32 MiB cache. The selected view releases its image when
selection changes. Preview decoding uses one worker and a maximum dimension of
1,200 pixels. OCR uses at most two workers and a maximum dimension of 2,400
pixels. Deleted items and disabled OCR cancel pending work and Vision requests.

## Automated checks

The test plan contains unit tests only. Clipboard tests use a private pasteboard
and a manual timer. Tests have a separate preferences domain. Storage tests
cover failed saves, failed deletion, byte limits, migration, orphan cleanup,
and deletion of external content files. Image tests check cache cost and OCR
worker limits. Search tests include text beyond the title and preview limits.

Run the same dependency checks as pull request CI:

```sh
xcodebuild -project Lodge.xcodeproj -scheme Lodge \
  -configuration Debug -destination 'platform=macOS' \
  -disableAutomaticPackageResolution -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO test
```

Pull requests and main-branch changes run the unit tests. The release workflow
runs them before it creates a release tag. Both workflows use the committed
`Package.resolved` file.

## Performance checks

`PerformanceTests` measures exact search over 200 and 999 documents. Each
document contains approximately 6,000 characters and a match near the end.
The measurements exclude fixture preparation and do not use the result cache.
Use the Xcode result bundle to compare repeated runs on the same machine.

On 6 September 2026, a Debug run on an arm64 MacBook Pro with macOS 26.6.2
gave median search times of 6.9 ms for 200 documents and 33.5 ms for 999 documents.
Each test measured ten searches. These figures describe this fixture and machine;
they are not an end-to-end typing latency measurement.

The `com.nklmilojevic.Lodge` signposts in the `Performance` category record
copy preparation, storage operations, search, image previews, and popup opening.
They do not contain clipboard text. The popup interval measures the open method,
not completion of the first rendered frame.

For a manual check, use a test macOS account with synthetic history:

1. Test histories of 200 and 999 items, including long text and large images.
2. Record popup opening and typing with Instruments Time Profiler and signposts.
3. Navigate through images repeatedly. Check that memory returns to a stable
   range after pending image work completes.
4. Leave the popup closed for five minutes. Record idle CPU and wakeups with OCR
   complete. Repeat with OCR processing to separate the two cases.
5. Switch between compact and split views. Drag the divider, reopen the popup,
   and check full text selection in the sheet.

The unit benchmark does not measure rendered popup latency, image navigation
memory, or idle CPU. These manual measurements are not yet recorded here.
