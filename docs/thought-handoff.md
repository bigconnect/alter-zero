# The thought hand-off — a thought gives its rows to the call it led to

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

The first content it held was the thought itself: its header settled into the
`Thought for …` line with the last rows of thought still under it until the
call's batch landed. That kept the box still, but the thought's text outlived
its phase — for a fraction of a second after a quick `skill` call, for as long
as a long command took to write — and read as a flash of stale thought:

> this shows in the TUI fast then removed fast

So the rows go to the **call** instead, the moment the model starts it.

## The design

**The thought settles in place.** At `ThinkingEnd` the phase is recorded as
before (`App::finish_reasoning` — history order and the usage snap are
unchanged), but its line is not written to scrollback yet:

- `App::hold_thought` keeps the settled `Reasoning` for the strip, and
  `ui::reasoning::held_thought_lines` draws it as the block it settled from
  with its header settled in place — the very `Thought for …` line
  `reasoning_lines` commits — over the same tail of thought. Same rows, so the
  box does not move when the phase ends.
- The boundary queues the line and its spacer on `InlineViewport::hold`
  instead of `insert_before`: committed, but held back from the next flush.

**The call stands in at once.** The piece that ends a thought is the first
piece of the call it led to, and that piece names the call. From it the strip
shows the call waiting under its tool's name — `ToolDrafts::placeholder`, the
round's first call that will have a cell of its own but previews nothing as it
streams, drawn by `ToolDraft::waiting_cell` through the very renderer a
batch's not-yet-run sibling goes through:

```
Thought for 0s · 50 tokens (ctrl+o to expand)     ← the settled line, committed

● Skill                                            ← the call, on the thought's rows
  ⎿  Waiting…

⣀⣀⣀⣀⣀⣛⣀⣀ Working… (0s · ↓ 77 tokens · esc to interrupt)
```

When the model has finished writing it, the round's batch puts the real cell
on the same rows — `● Skill(web-search)` — and it runs. The thought's text is
gone the moment its phase is (Ctrl+O still expands it), the status line keeps
its one spacer, and the box does not move: the block stood on its header, up
to three rows of thought and a gap; what replaces it is the line and its spacer
in scrollback over the placeholder's two rows and the same gap, and the cell
that replaces the placeholder is never shorter than its header and its
`⎿ Waiting…`/`⎿ Running…` row.

The placeholder's rules all serve that last sentence:

- **One per round.** The calls after the first appear with the batch, which
  only adds rows. A placeholder per call could stand taller than the read
  group the batch's reads fold into (Verbose output off), and the box would
  rise as they folded.
- **Never under an open read group** (`ui::live::drafting_lines`): its cell
  keeps the slot between reads, and the call being written may be one more
  read that folds into it.
- **Not for a `write`**, whose own preview is its cell
  (`docs/write-streaming.md`), **nor a task call**, which has no cell anywhere
  — the checklist is its display (`docs/task-tools.md`).
- **It lasts until the batch takes the round** (`ToolDrafts::adopt`), across
  the round's announcement (`seal`) — the instant before the batch, or a
  subagent's whole run when the round launched one — and goes at any turn
  edge (`clear`). An agent launch **retires** its call
  (`ToolDrafts::retire`, from `App::start_agent_group`): the agent group is
  its cell, and a placeholder left behind would wait for a call long since
  run.
- **It is a cell like a preview**: the piece that opens it finalises the
  streaming text before it (invariant 4 — `ToolDrafts::opens_cell`, read by
  the main boundary through `push` and by a subagent's fold through
  `AgentRun::will_flush_segment`), and the subagent session view shows its
  agent's the same way. A retry withdraws it with the attempt, and says why
  (`Withdrawn::live`); Esc's undo ignores it, since it stood in for a call
  that never ran. The Ctrl+O transcript shows it in its live tail too.

**The hold bridges the rest.** `ui::holds_thought` is the pure decision:
something is held, the conversation on screen is mid-turn, no modal prompt
replaces the region, the thought is still the newest record of that
conversation's history, and nothing else has taken the preview slot — no call
queued or streaming into a cell of its own, no agent group, no open
read/search group, no new thinking phase, no reply text beyond whitespace.
`preview_rows`/`preview_lines` draw the held thought first while it holds.

The newest-record rule ties the hold to the thought's own round. A round
whose only call is a task call records it with no cell (`docs/task-tools.md`):
the round has moved past the thought and nothing will land on its rows, so the
line commits at once rather than staying held through the next request.
The first frame it stops holding, `Session::sync_held_thought` (run at the top
of the draw tick and of `draw_conversation`) releases the held line into the
queue and drops the thought, so that frame writes the line and its spacer
above and draws the new content on the rows the thought's tail had.

Since the call's first piece takes the slot, the held view — the settled line
over the thought's tail — lasts at most the frame that can fall between the
phase's end and that piece, which the backend sends back to back. What it
still covers for longer is a thought the model follows with whitespace before
its call, and one followed only by a task call, until the call is recorded.

**Order is kept by construction.** `InlineViewport::insert_before` releases
the held lines ahead of whatever it queues, so a cell that commits before the
next frame (a `skill` call resolves within one) lands *under* the thought's
line in scrollback, as it does in history — no commit site needs to know a
line is held. An empty batch releases nothing.

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
(`settle_agent_reasoning`'s `hold`), its slot read off the viewed run.

## What it does not change

- **Between rounds** the strip is the status line under the cell's one
  spacer — nothing is held there, because no thought is settling.
- **A thought followed only by a task call** keeps its text under the settled
  line until the call is recorded: a task call has no cell to stand in with,
  and the line then commits with the box lifting by the rows the thought
  had, as the checklist takes its place under the status line.
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

- `ui::tests::held_thought`: the held view stands on the block's rows with its
  header settled into the committed line; the call's first piece takes the
  slot at once as `● Skill` over `⎿ Waiting…`, the box still from the thought
  to the placeholder and the placeholder never taller than the batch's cell;
  no placeholder stands under an open read group; the hold gives way to a
  streaming `write`, the reply's first words (not whitespace), a new phase, a
  modal and the turn's end; a record after the thought (a task call, an
  agent's hook note) ends the hold; nothing holds a row between rounds; a
  subagent's thought is held in its own strip and gives way to its call's
  placeholder. `app::tests::drafts`: the placeholder's rules — one per round,
  none for a `write` or a task call, a name that arrives late, its life from
  the first piece to the batch across the announcement, an agent launch
  retiring it, a retry counting it and Esc's undo not. `app::tests::reasoning`:
  the hold's lifecycle, dropped by a new turn and by `/clear`.
  `agents::tests::a_subagents_call_stands_in_after_its_text` and
  `ui::tests::transcript::ctrl_o_shows_a_call_being_written_waiting_as_the_strip_does`.
  Every guard is mutation-checked — each fails its test when removed.
- `scripts/smoke.sh` **Phase 153** samples four turns ~20 times a second with
  Phase 121's double-capture rule: no hop while the hand-off is under way, the
  call's placeholder seen, the thought's text never lingering under its
  settled line (still there 150 ms later), and never more than one blank row
  above the status line. The default offline turn runs on a terminal with
  room below the box (no purge rebuild; the thought's line and each cell
  exactly once, the thought's own text never in scrollback) and on an 80×16
  one, where the box sits on the bottom row. Two more go through the real
  backend against a paced stub provider (ported from
  fix/box-flicker-after-thinking): a `bash` call written over about a second,
  then a three-second round boundary; and a thought followed only by a
  `taskcreate`, then a request that fails with a 500 once, after which the
  thought's line must be in scrollback exactly once. The pre-fix binary fails
  the first three turns (the hop), the floor's binary the blank rows, and
  e97ef69's — the held thought alone, before the placeholder, the
  newest-record rule and the retry fix — the missing placeholder and the
  lingering thought in the first three and the retried line in the fourth.
- Real provider, ClinePass's `deepseek-v4.1-flash-1017`: with the held
  thought, the reported prompt at 100×30, 80×24 and 80×14 — no hop at the
  thought → `skill` hand-off, and exactly one blank row above the status line
  in every mid-turn frame. With the stand-in, five more turns, one of them a
  thought → `bash` hand-off: no hop at any thought → call hand-off, and one
  blank row above the status line in every mid-turn frame but a single 9 ms
  one, where the reply's own blank line between two paragraphs was the
  frontier. The only hops were thought → reply lifts (above), a row each.
