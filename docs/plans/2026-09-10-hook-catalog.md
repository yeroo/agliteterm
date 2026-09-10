# Hook validation catalog, 2026-09-10 (#60)

The opt-in installer validates the event names, handler availability, and handler-field types
documented in the [Claude Code hook reference](https://code.claude.com/docs/en/hooks) on this date.
This is a dated compatibility snapshot, not a rolling promise about future Claude versions.

Known event or field aliases with different case refuse. Fields belonging to another known
handler kind also refuse; prompt `continueOnBlock` is not an agent/command field. Unknown event
and optional-field extensions retain their names and values, subject to the existing JSON and
entry-shape checks. Unknown handler kinds still refuse, as before. No permission-rule, URL or
model-name semantics are invented, and no configuration value is silently normalized.

All validation precedes the first destination write. Private installer fixtures check every
catalogued event spelling, case aliases, handler applicability, correct optional values and
unknown-extension preservation. Rejected inputs must preserve a recursive hash of all fixture
files, including profiles, settings, helper copies and backups. Tests invoke no real Claude and
never use the user's actual profile or settings paths.
