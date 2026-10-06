---
description: Write a handoff note before moving this work to another computer (Claude Portable)
---
The user is about to move this work to another computer via the portable drive. Rewrite the handoff file whose path is given in the "Handoff note" section of the Claude Portable context, creating it if it doesn't exist. It is a current snapshot, not a log. Keep it under about 60 lines and write it in the language the user writes in:

- **Goal and status**: what we are building and where it stands.
- **Done this session**: key changes, with file paths relative to the project root.
- **Next steps**: concrete and in order. Split them into "on the other machine" (for example: build and test the Swift target on macOS with `swift build` or `xcodebuild`) and "anywhere".
- **Open problems**: failing builds or tests with the exact error text, and what was already tried.
- **Decisions and gotchas** worth not rediscovering.
- **First commands to run** on the next machine.

Extra notes from the user: $ARGUMENTS

Then confirm in one or two lines that it is saved, and remind the user to exit Claude (/exit) before ejecting the drive.
