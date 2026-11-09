# The thought hand-off — an ended thought waits a moment for the next cell

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

## Two fixes that were replaced

**A preview floor.** Each frame, the strip reserved what its slot had a frame
ago less every row committed since, padding with blank rows —
`StreamRender`'s own rule inside a reply (`docs/slow-stream.md`), lifted to
every hand-off between the strip's cells. The hop was gone, but the padding
was blank rows, and they showed wherever the next content was more than a
moment away: a `bash` cell's tall live tail settling into its shorter peek
between rounds left three empty lines over the status line until the next
request answered — seconds, not frames.

**A hold.** At `ThinkingEnd` the block's header settled *in place* into the
`Thought for …` line, the thought's tail stayed under it, and that line was
held back from scrollback (a held-line queue in `InlineViewport`, released by
any later `insert_before`) until a ten-condition predicate said something had
taken the slot. No hop, no blank rows — but the settled line stood over the
thought for as long as the next cell took to arrive:

```
Thought for 0s · 48 tokens (ctrl+o to expand)
  ⎿  The user wants …
     …
```

A call with no live preview (an `edit`, a long `bash` command) can take a
second or more to generate on a slower model or a large edit, so this was no
flash: it read as a finished thought that had not finished, and it was
reported as such. It also cost some 1,200 lines — the
viewport's queue, a display state on `App`, the predicate, a release at every
draw, the drops in every rebuild path — to keep three rows still for a few
frames.

## The design: a settle grace

Measured live (OpenRouter, `recursive/flint-v1.0:free` at `medium`, timing
the stream's own deltas): thoughts ran 0.3–4.8 s, and a call's arguments were
complete **17–120 ms** after its thought ended for a `skill` load, a short
`bash`, an `edit` — but **406–642 ms** for a `bash` command carrying a long
path or URL, which is what the web-search skill's commands are. The hop lives
in that interval, so the fix only has to wait it out.

**`ThinkingEnd` stops the clock, not the block.** The phase stays open —
`App::reasoning` keeps its text, the strip keeps drawing the same live
`● Thinking…` block — and the boundary's `ThinkingClock` records when it
ended (`clock.end`), so the status line's `Thinking for Ns` and the settled
`Thought for Ns` read the time the model actually thought.

**The next thing that draws or records settles it — first.** Before folding
any event, the boundary asks `StreamEvent::settles_ended_thought`; for
everything that draws a cell or records an item (the call's batch, a task
call, an agent launch, the reply's first words, a new phase, a hook note, the
turn's end or a backend error) it runs the ordinary `Session::settle_reasoning`
before the event's own work. The `Thought for …` line commits ahead of what
the event commits, and the frame that shows the event's cell shows the line
above it, on the rows the block stood on:

```
● Thinking…                                        ← the block, unchanged
  ⎿  The user wants to know …
     first.
     Note: … Let's actually search.

⣀⣀⣀⣀⣀⣛⣀⣀ Working… (0s · ↓ 77 tokens · esc to interrupt)
```

```
Thought for 0s · 50 tokens (ctrl+o to expand)     ← committed in the batch's frame
                                                   ← its spacer
● Skill(web-search)                                ← the cell, on the block's rows
  ⎿  Running…

⣀⣀⣀⣀⣀⣘⣃⣀ Working… (0s · ↑ 6.4k tokens · esc to interrupt)
```

What leaves the block up draws nothing in the preview slot and records
nothing: the pieces of the call being generated, blank text (some models send
`\n\n` before a call), the round's usage frame and its call ids. A piece that
opens a previewed `write` draws a cell after all, so the main session settles
on `App::push_tool_call_fragment`'s answer and the agent view on
`AgentRun::will_flush_segment`.

**The grace is bounded.** Past `THOUGHT_SETTLE_GRACE` (a second) the draw
tick settles it whatever comes next, so a call that takes longer to write
never leaves a block claiming a thought that is over. 300 ms was tried first:
it covered the short calls, but live, the web-search hand-offs still bounced
three rows for 94–155 ms — the block settling at its bound, the call's cell
landing just after. A second covers the slowest hand-off measured by half
again, and the offline demo's scripted one (about 0.8 s for the default
turn's three calls). The wait costs nothing on any other hand-off, since only
the call's own pieces and blank text extend it.

**Order is kept by construction, and nothing is held.** The thought is not in
history until it settles, and the settle runs before anything is recorded
after it, so scrollback, history and a resize's rebuild agree with no queue to
release: a purge rebuild during the grace regenerates history without the
thought and the strip keeps drawing its block from the open phase.

Three details follow from the phase staying open:

- **The round's usage frame can land first.** The backend sends `Usage`, then
  the round's call ids, then its batch. `App::apply_usage` (and
  `AgentRun::apply`) keep a frame's `reasoning_tokens` while a phase is still
  open and snap them when it is recorded (`round_reasoning_due`), so the count
  is neither missed nor carried into the next round — and the committed line
  carries the provider's count rather than the estimate. Settling at `Usage`
  instead would leave a draw room to land between it and the batch.
- **A retry voids the attempt.** `Retrying` neither settles nor waits: the
  open phase is withdrawn with the attempt it belongs to, as it always was,
  with no committed line to rebuild away.
- **Blank text stays for the reply.** Text that arrives during the grace is
  blank by construction (anything else settles first), and the settle leaves
  it in the buffer for the reply it starts, rather than flushing it as though
  it came before the thought.

**The agent session view** follows the same rule with its per-agent clocks
(`Session::agent_thinking_clocks`): a viewed agent's `ThinkingEnd` ends its
clock, the agent's next event that draws or records settles it, and the
roster tick settles any whose grace ran out. An agent not on screen settles at
once, having no block to keep up.

## What it does not change

- **A call slower than the grace** — a long `edit` written without a preview,
  a slow provider — settles at a second and the box moves once more when the
  cell lands, as it did before any fix: a layout change seconds apart, not the
  frames-apart bounce. (A `write` previews its file as it streams, so its first
  piece already settles the thought.)
- **A thought giving way to the reply** still lifts the box a row: the
  frontier's one row is shorter than the thought's tail. v0.18.0 does the same.
- **Between rounds** nothing is held: the status line sits one spacer under
  the last cell.

## Testing

- `app::tests::reasoning`: `ThinkingClock` (running, frozen at the end, a
  second end ignored, due only once the grace is over) and the usage frame
  that lands before its thought is recorded (snapped once recorded, split over
  the round, spent once, dropped with the phase); `agents::tests` the same rule
  on a subagent's run; `stream::tests::event` which events settle an ended
  thought.
- `scripts/smoke.sh` **Phase 153** samples four turns ~20 times a second with
  Phase 121's double-capture rule: the real backend against a paced stub
  provider writing its call over ~480 ms, inside the grace, at 100×30 and at
  80×16 with the box on the bottom row (no hop, the settled line never on
  screen with the thought, one blank row above the status line, the line once
  and straight over the call); a call written over about two and a half
  seconds (the block settles before the cell lands); a thought, a lone
  `taskcreate` and a retried request (the line reaches scrollback once); and
  the offline demo turn (no hop, line and cells once, no purge rebuild). With
  the grace set to zero — the old collapse — the quick turns and the demo fail
  on the hop; the hold's binary fails on the thought left under its line.
- Live, the reported prompt against OpenRouter's `recursive/flint-v1.0:free`
  at `medium`, sampled every few milliseconds at 100×30: every thought → call
  hand-off of the turn (a `skill` load and three web searches) committed its
  line in the same sample its call's cell appeared, with no rise of the box
  between; the hold's binary, on the same prompt, showed its settled line over
  the thought for two seconds.
