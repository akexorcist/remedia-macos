# Project conventions

- Default to no comment. Code should be self-explanatory; never add a comment that restates what the code does.
- The only comments worth keeping are ADR-style "why," and only when the why is genuinely non-obvious from the code itself: a hidden constraint, a workaround for a specific bug, a subtle concurrency/ordering requirement, or a decision that looks wrong until you know the reason. If a reasonable reader would ask "why is this here?", that's a comment worth keeping — not "what does this do?".
- Keep the ones you do write as short as possible — one line, not a paragraph. State the constraint/reason directly; skip preamble, background, and restating the surrounding code.
- This applies to every agent working in this repo, not just the one that wrote the code.
