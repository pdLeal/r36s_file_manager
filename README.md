# 📁 R36s File Manager

> A terminal-based file manager and library organizer for EmulationStation game collections.

The **R36s File Manager** started as a small personal project: a Bash script created to study, practice programming and solve a very specific problem on an R36s handheld console — keeping a large ROM library and its associated files organized.

What started as a simple file-management script has gradually grown into something closer to a **specialized CLI for managing EmulationStation game libraries**.

It is still far from being a complete or universal solution, and there are plenty of rough edges along the way. But the project has evolved considerably from its original idea.


---

## What It Does (Or Tries To)

The R36s File Manager analyzes both the filesystem and EmulationStation's `gamelist.xml` to build a model of the game library.

Instead of simply looking at filenames, the application compares filesystem data with XML metadata and classifies games, assets and supporting files according to their relationships.

The project currently uses concepts such as:

- **Valid** — files that exist and are correctly associated with a valid game.
- **Orphan** — files that exist on the filesystem but have no valid parent game.
- **Ghost** — entries referenced by `gamelist.xml` whose corresponding files do not exist.
- **Linked** — files without their own XML entry that can still be associated with a known game.
- **Unlinked** — files that cannot be associated with a known game.
- **Unknown** — files that could not be confidently classified.

This classification model allows the application to inspect not only ROMs, but also assets and auxiliary files associated with them.

---

## Current Capabilities

### Library analysis

The application can analyze a system directory and build a representation of its current game library.

The analysis pipeline currently:

1. Discovers files in the filesystem.
2. Reads game entries and asset references from `gamelist.xml`.
3. Validates XML game entries against files on disk.
4. Identifies missing XML references.
5. Detects ROM candidates that are not present in the XML.
6. Groups files by basename to identify relationships.
7. Classifies remaining files according to their type and relationship with games.
8. Builds indexes for files referenced by multiple games or XML tags.
9. Generates statistics and a dashboard for the analyzed system.

The application distinguishes between games, assets and supporting files instead of treating every file as an independent object.

### Game classification

Games can currently be separated into collections such as:

- All games
- XML games
- Orphan games
- Ghost games

This makes it possible to inspect inconsistencies between the filesystem and `gamelist.xml` directly from the terminal.

### Asset classification

The same relationship model is applied to common EmulationStation assets, including:

- Images
- Videos
- Marquees
- Thumbnails

Assets can be classified as valid, orphan, linked, unlinked or ghost depending on the state of the game and the referenced file.

The project also maintains inverted indexes capable of representing situations where the same physical asset is referenced by multiple games or XML tags.

This is important because **one physical file does not necessarily represent one relationship**.

### Auxiliary and configuration files

The classifier also attempts to identify files commonly associated with games or emulators, including categories such as: Saves, Save states, Configuration files, Metadata and more.

The classification is based on extension information and filename relationships rather than assuming that every file in a game directory is a ROM.

### Related-file discovery

When a game is selected, the application can display its associated files and distinguish between its different relationships.

This allows a game to be treated as a collection rather than merely a single ROM file.

---

## Game Management

The project is no longer limited to analysis.

For individual games, the current CLI provides operations such as:

- **Move Game**
- **Copy Game**
- **Delete Game**
- **See Metadata**
- **Edit Metadata**
- **Add an orphan game to `gamelist.xml`**
- **Remove a ghost entry from `gamelist.xml`**
- **See Related Files**

The available actions depend on the current status of the selected game. For example, orphan games can be added to `gamelist.xml`, while ghost games can have their invalid XML entries removed. Also, moving, copying and deleting can perform the same action optionally to related files and gamelist.xml entries.

---

## `gamelist.xml` Management

One of the main goals of the project is to keep the filesystem and EmulationStation metadata synchronized.

The application can currently:

- Read `gamelist.xml`.
- Display game metadata.
- Add orphan games to the XML.
- Remove ghost entries.
- Transfer XML entries between game directories.
- Edit metadata.
- Create a new `gamelist.xml` when necessary.
- Validate generated XML.
- Normalize generated XML formatting.

When the application modifies a game entry, it does not simply append raw text to the XML.

Instead, the current workflow creates a temporary XML document, applies an XSLT transformation, formats the resulting document and validates it before replacing the destination `gamelist.xml`. 

This makes XML manipulation considerably safer than treating `gamelist.xml` as a plain text file.

---

## Metadata Editing

Game metadata can be edited through an external text editor.

The current implementation opens the generated XML node in VS Code (personal preference) and waits for the editor to close before continuing the operation.

This approach is intentional: rather than building a complete metadata editor inside the CLI, the project currently delegates free-form XML editing to a text editor while keeping the resulting document under XML validation.

---

## Architecture

Although the project is written in Bash, its internal structure is becoming increasingly modular.

The main workflow is roughly:

```text
Filesystem
    │
    ├── Discover files
    │
    └── gamelist.xml
            │
            ▼
       Classification
            │
      ┌─────┼──────────┐
      ▼     ▼          ▼
    Valid  Orphan     Ghost
      │     │           |
      └─────└────────┐  └──┐
                     ▼     ▼
                File association ─────┐
                     │                │
              ┌──────┴──────┐         │
              ▼             ▼         ▼
           Linked        Unlinked   Orphan
```

The analysis is performed in multiple stages, progressively removing already-classified files from the unclassified collection.

The project also uses associative arrays and reference indexes extensively to represent relationships that would normally be modeled using richer data structures in other languages.

This is one of the more challenging aspects of the project — and one of the reasons it has grown considerably beyond its original “simple Bash script” scope.

---

## Requirements

### Bash

The project requires:

- **Bash 4.3 or newer**

The implementation relies heavily on Bash features such as:

- Associative arrays
- Namerefs (`local -n`)
- Arrays
- Extended pattern matching
- `mapfile`
- `[[ ... ]]`
- Process substitution

Therefore, older Bash versions are not supported.

### External dependencies

Although the goal is to keep the project primarily implemented in Bash, it is **not completely dependency-free**.

The current implementation relies on external Unix utilities, including:

- `xmlstarlet`
- `xsltproc`
- `rsync`
- `find`
- `sed`
- `awk`
- `mktemp`
- `sudo`

The project also currently integrates with **VS Code** for metadata editing.

`xmlstarlet` is particularly important because it is used for XML extraction, editing, formatting and validation. `xsltproc` is used during XML transformation workflows.

The project also expects its auxiliary extension database to be available through `aux_ext.txt`.

---

## Installation

At the moment, there is no formal package or installation system.

The project is currently intended to be run from a Unix-like terminal with the required dependencies installed.

---

## Current Limitations

This project is still experimental.

Some important limitations should be considered before using it on a valuable game collection.

### Terminal only

The application currently provides a terminal-based interface.

There is no graphical interface or web interface.

The goal is intentionally to keep the tool lightweight and usable directly from a Linux terminal or similar environment.

### No batch operations yet

Game operations currently work on individually selected games.

There is **no complete batch-operation system yet** for tasks such as:

- Moving multiple selected games.
- Deleting multiple games.
- Copying an entire collection according to filters.
- Applying metadata changes to multiple games.
- Automatically fixing an entire category of inconsistencies.

> **This is currently one of the main planned areas of development.**

### Limited cross-environment testing

The project was created around a real-world R36s use case and has primarily been tested against the author's own environment.

It has **not yet been extensively tested across different R36s firmware versions, EmulationStation configurations, operating systems or other handheld distributions**.

Therefore, compatibility with other environments should currently be considered experimental.

### Heuristic classification

Not every file can be classified with absolute certainty.

Some classifications depend on:

- File extension.
- Filename/basename relationships.
- EmulationStation metadata.
- Known auxiliary-file patterns.

This can produce ambiguous cases, particularly with systems that use unusual directory structures or file formats.

The project itself already identifies cases where extension-only ROM detection can produce false positives, such as systems with project/configuration-based game structures.

### External configuration assumptions

The application currently reads EmulationStation system information from configuration files such as `es_systems.cfg` or `es_systems.xml`.

There is currently no complete built-in fallback database if those configurations cannot be found.

### Permission requirements

Some filesystem and XML operations currently use `sudo`.

This means the script may require elevated permissions depending on where the game library is stored.

### Bugs are still expected

This is an active development project.

There are still known bugs, incomplete menu features, TODOs and areas of the classification pipeline that are being refined.

The current implementation should therefore be treated as a tool under development rather than a mature production-grade file manager.

---

## Roadmap

The immediate goal is to move from **individual game management** toward **library-wide automation**.

### Near-term goals

- [ ] Implement batch game operations.
- [ ] Allow filtering games before batch operations.
- [ ] Improve batch metadata editing.
- [ ] Refine classification heuristics.
- [ ] Reduce unnecessary external dependencies where practical.
- [ ] Improve error recovery during filesystem operations.
- [ ] Improve backup/rollback behavior for XML modifications.
- [ ] Expand testing with different directory layouts and game collections.

### Longer-term goals

- [ ] Test the application on different R36s environments.
- [ ] Test against different EmulationStation configurations.
- [ ] Test against other Linux-based handheld distributions.
- [ ] Improve portability beyond the original R36s environment.
- [ ] Document the classification model and supported file types.
- [ ] Establish a more formal release/testing process.

The long-term ambition is not necessarily to turn this into a massive standalone ecosystem.

Rather, the goal is to make the project reliable and portable enough that it could eventually become a useful contribution to other open-source projects and tools related to **EmulationStation, RetroArch and retro-gaming systems**.

---

## Project Status

**Early development / experimental**

The project has evolved significantly from its original purpose, but it is still strongly tied to the environment that motivated its creation.

In other words:

> It has grown from “a Bash script to organize my R36s” into “a CLI that might eventually become useful to more people.”

Getting from one to the other will require considerably more testing, abstraction and cleanup.

---

## Contributing

At the moment, the project has a **single developer**.

That said, the project is released under the **MIT License**, and contributions are welcome.

Possible contributions include:

- Bug fixes
- Testing on other environments
- Compatibility reports
- New system/file-format support
- Classification improvements
- Batch-operation ideas
- Documentation
- Refactoring
- Performance improvements
- New CLI features

If you have an R36s, another Linux-based retro handheld, or an EmulationStation/RetroArch setup that could help test the project, compatibility feedback is especially valuable.

---

## License

This project is licensed under the **MIT License**.

---

## Why Bash?

A fair question.

There are many languages that would make this project easier to build.

Bash was chosen mainly because the project began as a learning exercise and partly because the target environment is fundamentally Unix-like. Now I can't just move to another language 'cause of principles ~~moving would mean bash and all it's limitations gotta the best on me and I will never admit it!~~

Working within Bash has also forced the project to solve problems involving:

- Associative data structures.
- File relationships.
- Process pipelines.
- XML manipulation.
- Error propagation.
- Temporary files.
- Filesystem operations.
- State management.
- Interactive CLI design.

Some of those problems would be trivial with a database, a proper object model or a higher-level language.

Doing them in Bash is considerably less trivial.

That is also part of the point.

---

## Final Thoughts

The R36s File Manager was never planned as a serious software project.

It started because I wanted a small project to study with and solve a real problem at the same time.

Somewhere along the way, the “small Bash script” started acquiring classification pipelines, relationship indexes, XML transformations, validation, menus, file operations and enough state management to make me question several of my life choices.

At this point, it is becoming something more interesting.

The immediate objective is simple:

**Make it reliable enough to safely manage entire libraries in batches so I can clean the junk out of my personal R36s.**

After that:

**Test it outside the environment where it was born.**

And eventually, if the project gets far enough:

**Maybe it can become a useful little tool for the wider EmulationStation / RetroArch / retro-gaming open-source ecosystem.**

For now, it is still a work in progress.

---

*Powered by caffeine and the eternal fear of forgetting how to code.*
