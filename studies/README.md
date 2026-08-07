# studies

Written-up findings: things that were tried in [`../experiments/`](../experiments/README.md), worked
(or failed instructively), and are worth recording properly -- with the reasoning, not just the
result.

A study earns its place here once it changed a decision in the main project. Nothing has closed yet;
every open question currently lives in `../experiments/README.md`.

See the main [README](../README.md) for the project itself, and [`../docs/gotchas.md`](../docs/gotchas.md)
for the mechanism-level findings -- systemd's parsing of a quoted executable behind a `-` prefix,
its silent tolerance of docker's `unless-stopped`, docker's absent systemd generator, the
`firewall-backend` vocabulary, and system-manager's `.wants` target substitution -- that were
established before this repo's docker plane was written, and are recorded as transcripts there
rather than as open questions here.
