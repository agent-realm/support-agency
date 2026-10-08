# Drills

A drill is one recorded run against a real target: the end-to-end test (`e2e-*`), or a run with
real agents (`agents-*`). Name each record `<kind>-<YYYY-MM-DD-HH_MM>.md`.

Every record has:

- **Target:** realm URL, the realm's ClickHouse version, the demo customer's ClickHouse
  version and lab, and the commit the run started from.
- **Commands:** exactly as run.
- **Output:** pasted, not described.
- **Verdict:** pass or fail.
- **Deviations:** anything done by hand. In an end-to-end run, a manual fix is a failure.

**Never paste the canary, a password or a credential file into a record.** The test never
prints the first two; check a pasted failure for them before committing. Records are
append-only: a re-run gets its own file.
