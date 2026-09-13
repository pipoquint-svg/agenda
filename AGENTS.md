# Agenda Codex Protocol

Before substantive work:

1. Verify the current branch and working tree.
2. Fetch `origin` and synchronize the current branch with its remote counterpart before reading the handoff. Preserve any uncommitted local work; never reset, discard, or overwrite local changes just to sync. If local and remote changes conflict, stop only for that genuine conflict.
3. Read this file.
4. Read `docs/implementation/CURRENT-HANDOFF.md`.
5. Verify the actual PR HEAD, diff, and CI state before acting.
6. Use the handoff as the current scope and acceptance criteria.

A short instruction such as `continue pelo handoff`, `prossiga`, or `continue` means: synchronize safely, read the current handoff, and execute it without requiring the user to paste the full task again.

## Autonomous CI loop

A commit or push is not completion when the active handoff requires CI.

After a push, monitor the new HEAD until required checks reach a terminal state. If a required check fails, inspect the failure, make the smallest safe correction, rerun relevant checks, push again, and monitor the new HEAD. Repeat until the current gate is satisfied or the handoff reaches a genuine human decision point.

Do not stop only because CI is pending or in progress.

## Scope discipline

Stay inside `CURRENT-HANDOFF.md`. Avoid unrelated refactors. Do not weaken tests or validated behavior to make CI pass. Do not change public behavior when the handoff is a parity/performance gate unless explicitly authorized.

Do not merge, cut over a public endpoint, start the next PR/gate, or make production changes unless the handoff explicitly says they are authorized.

## Shared handoff

At the end of each meaningful work cycle, update `docs/implementation/CURRENT-HANDOFF.md` with the verified current state: PR, branch, HEAD, completed work, CI status, blocker if any, and exact next objective.

Keep the handoff concise and current; historical detail belongs in dedicated reports.
