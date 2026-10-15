# Native working-version format

LensWorks adapts the frozen Compositor package reader/writer. Readable baseline
formats 1–11 remain supported. New LensWorks saves use format version 12; the
read-only Compositor snapshot and its format documentation remain unchanged.

A version-12 catalog working version includes `workingVersionID` in the project
manifest and a matching `LensWorks.json` within the same `.comp` package. The
record preserves its schema version, stable working-version UUID, catalog photo
UUID, canonical catalog path, original source path, document path and version
name. The manifest marker makes missing or mismatched identity a load error,
rather than silently treating an incomplete catalog version as standalone.
Standalone projects may omit the catalog identity record. Saving a catalog working
version under a different project path creates a new working-version UUID while
retaining photo/source links; normal Save preserves the UUID. Catalog-managed
paths and destinations that would replace originals or the catalog are rejected.

The writer validates source protection, serializes document assets and the
identity record into the same staged package, and publishes them together through
the retained atomic project writer. No independent external sidecar is required
for new saves. A failed publication must leave the previous project readable and
must not report the captured revision as saved. Source media and the retained
PhotoCatalog recipe schema remain unchanged.

This first format extension establishes the raster working-version relationship.
Compositions, recovery and portable export retain their explicit owning stories in
epic 24655.

## Independent named versions (sc-24672)

A catalog photo has any number of working versions. Each is its own `.comp`
package with its own `LensWorks.json` identity (UUID, name) and shares only the
photo and source links. Versions are created, duplicated, renamed, switched
between and deleted from the catalog's version list and from the editor's File
menu; every one of those is a registered command.

- **Duplicate** copies the package to a hidden staging folder beside it, gives the
  copy a new identity and name, and moves it into place whole. From the editor it
  instead saves the document as it is now (unsaved edits included) as the new
  version; the open version is not saved and its tab stays on it. Either way the
  source package is only read, in a coordinated read after any save of it that is
  still under way in a tab. On APFS the copy is a clone: it takes no room until
  one of the two versions changes. A new version's file name is its name cut to
  120 UTF-8 bytes between characters (a leading `.` becomes `-`, so the package is
  never hidden), then the start of its UUID.
- **Rename** rewrites the identity record's name only. The file name, the identity
  and the manifest are untouched.
- **Delete** asks first, refuses a version that is open in a tab (checked again
  after the answer), and moves the package to the Trash. The confirmation names the
  version confirmed; one given for anything else deletes nothing.
- **Agents** run every one of these, and the checkpoint commands, by the ids
  `get_state` lists (`checkpoints`, `workingVersion`, `otherVersions`, and the
  catalog's `workingVersions`), with names checked to at most 1,024 UTF-8 bytes. The
  version files they reach are held to the folders granted to automation. Deleting
  a version or a checkpoint waits for the person's Allow in LensWorks, which names
  exactly what goes; History Storage is the person's alone.

## Persistent undo and checkpoints (sc-24672)

Undo/redo history and named checkpoints are saved inside the package, in a
`History` folder published by the same atomic save as the document. The manifest
format version does not change: a build that predates history opens these
documents and, when it saves, writes a package without the folder.

```
History/index.json            schema, the manifest's SHA-256, entries, checkpoints, cursor
History/states/<revision>/    state.json and manifest.json (a project manifest) for one state
History/rasters/<id>.json     an 8-bit image as a row-major list of 256-pixel tiles
History/planes/<digest>.json  a float plane's tile list (its own manifest)
History/blobs/<aa>/<sha256>   tile and source bytes, named by content, LZFSE-compressed
```

Each entry records its identity, name, date, **origin** (`person` or `agent`;
missing reads as `person`; the app's command origin `user` is written as
`person`), the states it runs between and the layers selected at each end. A
checkpoint records its identity, name, date, origin and state. The cursor is the
state the document is in; when the document changed outside history since a step
or checkpoint recorded the state it is in, a save gives it a state of its own. An
index that does not decode, or whose `manifestSHA256` is not the package's
manifest, is ignored and the document opens without history. An index whose
`schema` is newer than this build's is not read either, but it is kept: the first
save over that package asks before it replaces the history (Save As leaves it).
The project's change watch fingerprints `History/index.json` too, so a save
elsewhere that only changes history is seen.

**Storage model.** A state names its pixels; the bytes live once in `blobs`
however many states share them, so a step costs the tiles it changed. Pixels the
document itself holds (`images`, `Sources`) are never copied into `History`: a
state that still shows a layer as the document does costs only its manifest. The
first time a layer's pixels change after it entered the document, its previous
pixels move into `History` once; every later step on it adds only its changed
tiles. Measured on a 4096 × 3072 8-bit layer of incompressible noise (48 MiB
raw), painting a 300-pixel dab per step and saving after each: the first step
added 41 MiB (the previous frame, once), each later step 0.9 MiB on average and
1.3 MiB at worst, against 48 MiB for a whole frame; a save took about 1.2 s.
Float planes are stored by the tiles and content hashes they already have; live
RAW source records and coverage are stored by the content hashes their package
files already have. A live RAW layer's developed pixels are not stored in a
state: the state keeps its source node (the recipe), and the pixels are developed
again from the original when the state is read back, as an export develops them.
A recipe change on a 512 × 384 live RAW layer costs about 3.9 KB of history per
saved step (it cost about 0.5 MB, a compressed developed float frame of
3 MiB, before). Restoring such a state needs the original, as export does. A save
carries the states the old package holds first, and clones a tile the old
`History` folder already has instead of compressing it again. Blobs are
decompressed through a stream that stops one byte past the size their record
allows.

**Memory.** Opening a document reads the index only. A state is read back when
Undo, Redo or Restore Checkpoint reaches it, off the main thread while the
session is busy, sharing every image already in memory. When the states held for
undo pass the in-memory limit (256 MiB), states the package holds leave memory
first; steps are dropped only when their states exist nowhere else. What
checkpoints hold (an unsaved one cannot leave memory) does not count against the
steps: they keep the limit for what only they hold.

**Limits and pruning.** Edit › History Storage… sets the most undo steps kept
(default 100; lowering it drops the oldest steps at once, and a package saved
under a higher limit opens within the lower one) and the most disk a document's `History` folder may take (default
1 GiB; "No limit" is offered). A save that would exceed the storage limit drops
the oldest undo steps first, then the furthest redo steps. It never drops a
checkpoint, the current state, or a file any kept state needs: what stays is
decided first and everything else is swept. When checkpoints and the current
state alone exceed the limit, every undo and redo step is removed, no checkpoint
is, and the person is told once, with the number of steps removed and the choice
of raising the limit or deleting checkpoints. Any save that removes steps says how
many and the limit, once per limit, and History Storage shows it; the steps are
gone from Undo in the open session too. Deleting a checkpoint asks for
confirmation.

**Crash consistency.** The `History` folder is assembled inside the staged
package and nothing outside it is written until the staged package replaces the
old one. A failure, or the process dying, at any point before that leaves the
previous package byte for byte as it was. Staged packages a killed save left
beside the project (`.LensWorks-<uuid>.comp`) are removed by a later successful
save once they are more than an hour old. A damaged or missing history file never
stops the document opening: the step that needs it refuses with a reason, and the
next save keeps what can still be read and names what it could not keep.

## Baked coverage (format 15, sc-24672)

"Bake and Delete" on a clipping source whose dependent is a live RAW layer with
its own mask switched off puts the coverage into the layer's **baked coverage**:
`coverageFile` (`<layer id>.coverage.plane`, a one-channel float plane over the
layer's own pixel grid) and `coveragePlaneArchiveReference`. Every composite
(canvas, export, flatten, merge, Copy Merged, a live mask it lends) multiplies the
layer's alpha by it beside the mask, and it follows the layer's grid through every
development from the original and through Image Size. The switched-off mask is left as it was, and no
layer is added. Duplicate Layer, Paste and a copy into another document carry it.
Only a live source layer may have one. A save writes format 15 only when a layer
has baked coverage; otherwise 13 for live RAW or float content, else 12. Format 14
is sc-25324's retained filter-plugin step and Invert on live RAW sources: this
change never writes it, and the reader takes the upgrade 13 → 14 → 15 in order (a
package that says 14 and holds a baked coverage is refused). Builds read 1–15.

**Format fixtures.** `native/Fixtures/ProjectFormats` holds one frozen package
per manifest version (1–13 and 15; version 14's arrives with sc-25324) and one with
a `History` folder per history schema. Versions 12, 13 and 15 were written by this product's save; 1–11 are assembled by hand in
the layout of the Compositor app's writer (`vendor/Compositor`, the version-11
writer), since no package it saved survives in its tree or history.
`ProjectFormatFixtureTests` opens each, compares every manifest and layer field
with the document it was frozen from, saves it in the lowest format that holds it
and reopens it, and fails when a version this build reads has no fixture: a new
manifest version or history schema needs its own frozen package before it can
merge.
