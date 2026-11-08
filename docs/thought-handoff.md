# The thought hand-off — a settled thought holds its rows for a moment, then stands alone

## The report

> prompt → thinking (medium) → flicker → the skill shows inline. It happens
> sometimes, not every time.

ClinePass, `cline-pass/deepseek-v4.1-flash-1017` at its default `medium`
thinking, asked *"Who is the current world chess champion? use skill tool
first dont produce intermediate response"*: the model thinks for a fraction of
a second, calls the `skill` tool to load `web-search`, and between the two the
screen jolts.

## What the frames showed

The run was recorded with `tmux pipe-pane` (each chunk timestamped) and
replayed through a terminal emulator one synchronized frame at a time — each
frame is everything up to an `ESC[?2026l`, exactly what a mode-2026 terminal
presents at once. Nothing was torn: no purge rebuild, no region clear, no
byte outside a synchronized update. What moved was the box (100×30, a fresh
screen):

| frame | time | footer row | what the frame shows |
| --- | --- | --- | --- |
| #32 | 13 145 ms | 16 | `● Thinking…` over three rows of thought |
| #33 | 13 169 ms | **13** | `Thought for 0s · 50 tokens` committed; the strip is the status line alone |
| #34–35 | to 13 236 ms | **13** | the same, the box three rows up with blank rows under the footer |
| #36 | 13 251 ms | 16 | `● Skill(web-search)` committed; the box back down |

Down, up three rows, down again ~80 ms later: the flicker.

## Why

The live region is **content-anchored** (CLAUDE.md invariant 3): a frame that
commits `c` rows to scrollback pushes it down by `c`, and a frame whose region
is `h` rows shorter pulls its bottom up by `h`. So the box rises exactly when
the strip sheds more rows than went to scrollback in the same frame.

A thinking phase did that at every hand-off to a tool call:

- The backend closes the phase on the round's **first tool-call piece**
  (`llm::backend::stream_round` sends `ThinkingEnd` ahead of the first
  `ToolCallDelta`), and the settle committed its collapsed `Thought for …`
  line and a spacer — two rows — at once.
- The block stood on five: the `● Thinking…` header, three rows of thought
  (`REASONING_PEEK_LINES`) and the gap under them.
- The call gets a cell only when its batch is **announced**, once its
  arguments have streamed and the stream has ended. Until then the strip had
  nothing to preview — only a `write` previews while it is generated
  (`docs/write-streaming.md`).

So for as long as the call took to generate, the box sat three rows up; the
batch's cell then pushed it back down. That interval is also why it happened
*sometimes*: when the arguments, the stream's end and the batch all arrive
inside the same frame as the end of the thought (the loop coalesces at
120 fps), no frame ever shows the hole. A subagent's session view settles its
own thoughts the same way and hopped the same way.

**Not a regression.** v0.18.0, built from its tag and driven through the same
offline turn at the same size, hops at the same frames by the same rows.

## The first fix, and why it was replaced

The first fix kept a **preview floor**: each frame, the strip reserved what
its slot had a frame ago less every row committed since, padding with blank
rows — `StreamRender`'s own rule inside a reply (`docs/slow-stream.md`),
lifted to every hand-off between the strip's cells. The hop was gone, but the
padding was **blank rows**, and they showed wherever the next content was more
than a moment away:

> it occupies 3 empty newlines — it should be 1 new line between
> `… +234 lines` and the status line indicator

That was a `bash` cell between rounds: its live tail (four output rows and its
`+N lines` footer) stood taller than its settled peek, so the floor held the
difference blank until the *next request* answered — seconds, not frames. The
same padding would have sat under a call that ran long after a read group
closed, and under a slow reply's first row. Measured on the same prompt: every
pre-floor frame had exactly one blank row above the status line; the floor's
runs had frames with two and four.

Blank rows held for a cell that is a whole request away are a layout bug of
their own. So the floor is gone, and the one hand-off that hopped *and* had
its next content seconds-or-less away, by construction — a thought settling at
its call's first piece — holds **content** instead.

## The second design, and why it changed

The floor's replacement settled the thought **in place**: the header became
the `Thought for …` line, the thought's tail stayed under it, and the call's
cell took those rows when it landed — however long that took. The hop was
gone, but a call that took its time to generate left the finished thought on
screen for all of it:

> After it finished thinking and waiting for the next output
> ```
> Thought for 0s · 48 tokens (ctrl+o to expand)
>   ⎿ in the Projects/...
> ```
> I want you to make it after thinking just show "Thought for 0s · 48 tokens
> (ctrl+o to expand)" dont show the "⎿ in the Projects/... "
>
> Make sure the implementation dont reserve newlines waiting for the next
> inline cell TUI output it should only 1 newline

Two requirements, then, on top of the original one: once a thought is over,
its line stands **alone** while the next output is on its way, with **one**
blank row under it — no tail, and no blank rows standing in for one — and a
quick call still must not bounce the box. Between them only one thing can
occupy the block's rows while a call is generated without being blank or the
finished thought: the block itself, for a moment.

## The design

**The block stays up for a moment, as it was.** At `ThinkingEnd` the phase is
recorded as before (`App::finish_reasoning` — history order and the usage snap
are unchanged), but its line is not written to scrollback yet:

- `App::hold_thought` keeps the settled `Reasoning` for the strip, with the
  frame clock's reading at the hold (`App::pulse`, the spinner picker's
  `opened_at` rule), and the strip draws the very block it settled from —
  `live_reasoning_lines` over the same text: the `● Thinking…` header, still
  blinking and shimmering, over the same tail. The status line's
  `Thinking for Ns` clause stays with it, frozen at the phase's length (the
  boundary's thinking clock stops at the settle). Same rows, so the box does
  not move when the phase ends, and nothing on screen says it ended yet.
- The boundary queues the line and its spacer on `InlineViewport::hold`
  instead of `insert_before`: committed, but held back from the next flush.

**Whatever comes next takes the rows — or the moment passes.**
`ui::holds_thought` is the pure decision: something is held and has stood for
less than `REASONING_HOLD` (300 ms, `App::held_thought_age`), the
conversation on screen is mid-turn, no modal prompt replaces the region, the
thought is still the newest record of that conversation's history, and
nothing else has taken the preview slot — no call queued or streaming into a
cell of its own, no agent group, no open read/search group, no new thinking
phase, no reply text beyond whitespace. `preview_rows`/`preview_lines` draw
the held block first while it holds.

The first frame it stops holding, `Session::sync_held_thought` (run at the top
of the draw tick, after the frame clock is injected, and of
`draw_conversation`) releases the held line into the queue and drops the
thought, so that frame writes the line and its spacer above — and either the
next cell lands on the rows the block had, or, when nothing came in time, the
strip is the status line alone, the line's spacer the one blank row above it:

```
● Thinking…                                         ← the block, still up
  ⎿  The user wants to know …
     first.
     Note: … Let's actually search.

⣀⣀⣀⣀⣀⣛⣀⣀ Working… (0s · ↓ 77 tokens · Thinking for 0s · esc to interrupt)
```

A quick call (the reported `skill` load took ~80 ms) lands inside the moment,
on the block's rows, the box exactly where it was:

```
Thought for 0s · 50 tokens (ctrl+o to expand)     ← now in scrollback
                                                   ← its spacer
● Skill(web-search)                                ← the cell, on the block's rows
  ⎿  Running…

⣀⣀⣀⣀⣀⣘⣃⣀ Working… (0s · ↑ 6.4k tokens · esc to interrupt)
```

A slower one finds the thought collapsed into its line alone:

```
Thought for 0s · 63 tokens (ctrl+o to expand)
                                                   ← one blank row
⣀⣀⣀⣀⣀⣛⣀⣀ Working… (1s · ↓ 348 tokens · esc to interrupt)
```

**300 ms** is long enough to cover a quick call's generation and short enough
to read as part of the thinking: nothing on screen tells a phase's end from
one that ran a beat longer, and the block, its clause and its tail all go in
one frame. The window is measured from the frame clock's last reading before
the hold, so it is up to one frame shorter than the constant.

**Order is kept by construction.** `InlineViewport::insert_before` releases
the held lines ahead of whatever it queues, so a cell that commits before the
next frame (a `skill` call resolves within one) lands *under* the thought's
line in scrollback, as it does in history — no commit site needs to know a
line is held. An empty batch releases nothing.

The newest-record rule ties the hold to the thought's own round. A round
whose only call is a task call records it with no cell (`docs/task-tools.md`):
the round has moved past the thought and nothing will land on its rows, so the
line commits at once rather than staying held through the next request.

**What drops a held thought unwritten.** Only a purge rebuild (`reflow`, and
`repaint_conversation`/`repaint_agent_view`, which drop it before they paint),
which regenerates the line from history. A quit flushes it (`restore`), since
it is committed content.

A `Retrying` does not touch it. A thought the failed attempt produced is
withdrawn from history with the attempt, and a withdrawal that took a record
rebuilds the screen (`retract_withdrawn_rows`, or the agent view's own
rebuild), which drops the held line: it never reaches scrollback. A thought
held from an earlier round belongs to that round and commits when it is let
go. The retry used to drop every held line itself, and that lost two lines:
a thought followed only by a task call, then a retried request — the thought
was still held, so its `Thought for …` line never reached scrollback (Ctrl+O
still showed it); and, in an agent session view, the viewed agent's held line
when the main conversation's request was retried.

**Where it holds.** Only at the phase's own end: an Esc or a backend error
settles at once, since the turn is ending and its own commits follow. The
agent session view holds the viewed agent's thought the same way
(`settle_agent_reasoning`'s `hold`), its slot read off the viewed run, its
clause added to the agent's synthesized status.

## What it does not change, and what it costs

- **A call slower than the moment** lifts the box: when the hold lapses, the
  block's rows give way to the line and its spacer, and the box rises by the
  difference (two rows under a two-line thought, three under a full block)
  until the call's cell lands and drops it back. That is the price of showing
  the line alone, as asked, without blank rows; past 300 ms it reads as the
  layout changing twice rather than a flicker. With the box on the bottom row
  the vacated rows sit blank under the footer meanwhile — the same rows any
  shrinking region leaves.
- **Between rounds** the strip is the status line under the cell's one
  spacer — nothing is held there, because no thought is settling.
- **A thought giving way to the reply** still lifts the box a row: the
  frontier's one row is shorter than the thought's tail, and the only ways to
  hide that are blank padding under the reply (the rejected floor) or holding
  the reply back. v0.18.0 does the same.
- **A read group closing under the next call** still lifts the box a row for
  that call's runtime — its two-row live cell settles into one line, a row
  short — for the same reason. v0.18.0 does the same.
- **The turn's end** with the spinner tip on settles the idle box one row
  higher (the tip row has no committed counterpart); a settle, not a bounce.

## Testing

- `ui::tests::held_thought`: the held block is the live block it settled from,
  header and tail, and never the settled line over its thought; the box does
  not move from the thought to a quick call (and while it is still being
  generated); the hold lapses at `REASONING_HOLD`, counted from the hold
  rather than the loop's start, after which nothing stands in the slot and
  the region opens on the status line; the status line keeps its
  `Thinking for Ns` clause while the block holds and drops it with the block;
  the hold gives way to a streaming `write`, the reply's first words (not
  whitespace), a new phase, a modal and the turn's end; a record after the
  thought (a task call, an agent's hook note) ends the hold; nothing holds a
  row between rounds; a subagent's thought is held, and lapses, in its own
  strip. `app::tests::reasoning`: the hold's lifecycle and its age on the
  frame clock, dropped by a new turn and by `/clear`. The time bound and the
  agent view's clause are mutation-checked — each fails its test when
  removed.
- `scripts/smoke.sh` **Phase 153** samples five turns ~20 times a second with
  Phase 121's double-capture rule: no sample shows the settled line with its
  thought, never more than one blank row above the status line, and a rise of
  the box only as the hold lapses, with the line alone on screen. Three turns
  generate their call slower than the hold and must show the line alone while
  they do: the default offline turn on a terminal with room below the box (no
  purge rebuild; the thought's line and each cell exactly once, the thought's
  own text never in scrollback) and on an 80×16 one, where the box sits on the
  bottom row, and the real backend against a paced stub provider (ported from
  fix/box-flicker-after-thinking) writing a `bash` call over about a second,
  then a three-second round boundary. A fourth is a thought followed only by
  a `taskcreate`, then a request that fails with a 500 once, after which the
  thought's line must be in scrollback exactly once. The fifth is the reported
  shape: a `bash` call whose cell lands 120 ms after the thought settles, where
  the box must never rise. The previous binary fails four turns (the settled
  line over its thought) and a build with a zero-length hold fails the fifth
  (the hop).
- Real provider: ClinePass, `cline-pass/deepseek-v4.1-flash-1017` at its
  default `medium`, sampled at the speed of `tmux capture-pane`: the reported
  prompt at 100×30, 80×24 and 80×14, a single long `bash` command, and three
  parallel calls whose batch took about half a second to land. No frame showed
  the settled line over its thought (the previous binary showed seven on the
  parallel prompt), the quick hand-offs held the box still, the slow one showed
  the line alone, one blank row above the status line, and the block, its
  clause and its tail went in one frame. The reply's own streaming can still
  pad the frontier for a frame (`docs/slow-stream.md`), on either binary.
