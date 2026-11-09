#!/usr/bin/env bash
# Phase 153 — a thought hands its rows straight to a quick call, and settles to its line alone

. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
smoke_begin

# THE THOUGHT HAND-OFF (docs/thought-handoff.md). The backend settles a
# thinking phase at the round's first tool-call piece, but the call has a cell
# only once its batch is announced. Collapsing the `● Thinking…` block at once
# lifted the box by the block's rows until the cell landed, then dropped it
# back — the flicker reported between a quick think and a `skill` call. The
# block now LINGERS through what shows nothing (the call's own pieces, the
# round's ids and usage) for up to THOUGHT_LINGER (300 ms) and settles the
# moment anything else arrives, so a call generated within that window takes
# the block's rows in the same frame its `Thought for …` line commits.
#
# A fix before this one held the settled line on the block's rows with the
# thought still under it until the call landed, which read as a stray tail of
# thought hanging off a finished line for as long as the call took: no sample
# may ever show the settled line with the thought still under it. And a fix
# before THAT held the rows blank, which sat as three empty lines over the
# status line between rounds: mid-turn the status line has exactly ONE blank
# row above it.
#
# Each turn is sampled ~20 times a second, each candidate confirmed against a
# second capture a beat later, Phase 121's rule (a torn frame lasts
# microseconds, a hop or a held gap as long as the call takes to generate).
# Five turns:
#   1. the default dummy turn — a paragraph, a two-line thought, then a
#      Read+Edit+Bash batch generated over about a second, longer than the
#      linger, so its thought settles to its line alone first — on a terminal
#      with room below the box, its byte stream checked for purge rebuilds and
#      its thought's line and cells for landing exactly once;
#   2. the same turn on a short terminal, where the box sits on the bottom row
#      and a rise strands blank rows under it;
#   3–5. the REAL backend against a paced stub provider: a call written well
#      inside the linger (no hop at all), a call written over about a second
#      (the line alone before the cell) and a three-second round boundary, and
#      a thought whose round records only a task call, then a retried request.
S153="${S}_thoughthandoff"
S153S="${S}_thoughthandoffshort"
RAW153="$SMOKE_TMP/phase153.raw"
THOUGHT153="Let me read the file first."

# The blank rows directly above the status line in a capture, or nothing when
# no status line is on screen.
gap_above_status() {
	printf '%s\n' "$1" | awk '
		/esc to interrupt/ { print blank; exit }
		/^[[:space:]]*$/ { blank++; next }
		{ blank = 0 }'
}

# watch_turn SESSION FOOTER THOUGHT [SETTLED_CELL] — sample a turn until its
# status line goes; sets W_SAMPLES, W_HOPS (confirmed rises of the FOOTER
# row while the status line was up — none counted once a sample shows
# SETTLED_CELL, whose round's end may lift the box), W_GAPS (confirmed
# samples with more than one blank row above the status line), W_HELD
# (samples showing the settled line with THOUGHT still on screen — the
# thought shows only in its live block, which the line replaces) and W_ALONE (a
# sample showed the settled line with neither THOUGHT nor SETTLED_CELL on
# screen: the linger ran out before the call's cell landed).
watch_turn() {
	local sess="$1" footer="$2" thought="$3" settled="${4:-}" vis again now prev=0 seen=0 gap
	W_SAMPLES=0
	W_HOPS=0
	W_GAPS=0
	W_HELD=0
	W_ALONE=0
	for _ in $(seq 1 600); do # up to ~30s
		vis="$(tmux capture-pane -t "$sess" -p)"
		W_SAMPLES=$((W_SAMPLES + 1))
		if printf '%s' "$vis" | grep -qF "esc to interrupt"; then
			seen=1
		elif [ "$seen" -eq 1 ]; then
			# The turn is over: its end collapses the strip into the summary,
			# which is a settle rather than a hop.
			break
		fi
		if printf '%s' "$vis" | grep -qE '^Thought for [0-9]+s'; then
			if printf '%s' "$vis" | grep -qF "$thought"; then
				W_HELD=$((W_HELD + 1))
				if [ "$W_HELD" -le 2 ]; then
					dump "$sess: the settled line with the thought still on screen (sample $W_SAMPLES)" "$vis"
				fi
			elif [ -n "$settled" ] && ! printf '%s' "$vis" | grep -qF "$settled"; then
				W_ALONE=1
			fi
		fi
		now=$(printf '%s\n' "$vis" | grep -nF "$footer" | tail -1 | cut -d: -f1)
		if [ "${now:-0}" -gt 0 ] && [ "$now" -lt "$prev" ]; then
			sleep 0.03
			again="$(tmux capture-pane -t "$sess" -p)"
			local now_again
			now_again=$(printf '%s\n' "$again" | grep -nF "$footer" | tail -1 | cut -d: -f1)
			if printf '%s' "$again" | grep -qF "esc to interrupt" &&
				{ [ -z "$settled" ] || ! printf '%s' "$again" | grep -qF "$settled"; } &&
				[ "${now_again:-0}" -gt 0 ] && [ "$now_again" -lt "$prev" ]; then
				W_HOPS=$((W_HOPS + 1))
				if [ "$W_HOPS" -le 2 ]; then
					dump "$sess: the box hopped up from row $prev to row $now_again (sample $W_SAMPLES)" "$again"
				fi
			else
				now="${now_again:-$now}"
			fi
		fi
		prev="${now:-$prev}"
		gap="$(gap_above_status "$vis")"
		if [ "${gap:-1}" -gt 1 ]; then
			sleep 0.03
			again="$(tmux capture-pane -t "$sess" -p)"
			gap="$(gap_above_status "$again")"
			if [ "${gap:-1}" -gt 1 ]; then
				W_GAPS=$((W_GAPS + 1))
				if [ "$W_GAPS" -le 2 ]; then
					dump "$sess: $gap blank rows above the status line (sample $W_SAMPLES)" "$again"
				fi
			fi
		fi
		sleep 0.05
	done
	[ "$seen" -eq 1 ] || fail "$sess: the turn never showed its status line"
	if [ "$W_SAMPLES" -lt 20 ]; then
		fail "$sess: only $W_SAMPLES samples of the turn: the watch saw too little to mean anything"
	fi
}

# expect_watch WHAT [still] — the verdicts on the last watch_turn: never the
# settled line with the thought still under it, never more than one blank row
# above the status line, and — with `still` — no hop at all, for a call that
# lands inside the linger.
expect_watch() {
	if [ "$W_HELD" -ne 0 ]; then
		fail "$1: a sample showed the settled 'Thought for' line with the thought still on screen: a settled thought is its line alone (see the frames above)"
	fi
	if [ "$W_GAPS" -ne 0 ]; then
		fail "$1: $W_GAPS sample(s) held more than one blank row above the status line: rows were held blank instead of collapsing to one spacer (see the frames above)"
	fi
	if [ "${2:-}" = still ] && [ "$W_HOPS" -ne 0 ]; then
		fail "$1: the box hopped up $W_HOPS time(s) mid-turn: the thought gave its rows up before the call that followed it could take them (see the frames above)"
	fi
}

# ---- 1. the dummy turn, with room below the box ------------------------------
launch "$S153" 80 24
tmux pipe-pane -t "$S153" -o "cat > $RAW153"
submit "$S153" "$USER_MSG"
watch_turn "$S153" 'dummy_model_name ·' "$THOUGHT153"
note "tall: sampled $W_SAMPLES times; box hops=$W_HOPS; held gaps=$W_GAPS; line with the thought under it=$W_HELD"
expect_watch "tall"
wait_summaries 20 "$S153" 1 >/dev/null || fail "the default turn never finished"
tmux pipe-pane -t "$S153" # close the recording before quitting

final="$(pane "$S153" -S -200)"
dump "captured pane + scrollback (the settled turn)" "$final"
# Liveness: the turn reached the hand-off, so a quiet watch is a real pass.
expect_eq "$(grep -cE '^Thought for [0-9]+s' <<<"$final")" "1" \
	"the thought did not settle into exactly one 'Thought for' line"
expect_lacks "$final" -F "$THOUGHT153" "the thought's own text reached the conversation: only its line may commit"
expect_eq "$(grep -cF '● Read(about.py)' <<<"$final")" "1" "the read's cell is not there exactly once"
expect_eq "$(grep -cF '● Edit(about.py)' <<<"$final")" "1" "the edit's cell is not there exactly once"
expect_eq "$(grep -cF '● Bash(python3 about.py)' <<<"$final")" "1" "the run's cell is not there exactly once"
purges=$(grep -c $'\x1b\\[3J' "$RAW153" 2>/dev/null || true)
expect_eq "${purges:-0}" "0" "the turn purge-rebuilt the screen"
keys "$S153" C-c
wait_gone 10 "$S153" || fail "the app did not quit on Ctrl+C"

# ---- 2. the dummy turn on a short terminal: the box on the bottom row --------
launch "$S153S" 80 16
submit "$S153S" "$USER_MSG"
watch_turn "$S153S" 'dummy_model_name ·' "$THOUGHT153"
note "short: sampled $W_SAMPLES times; box hops=$W_HOPS; held gaps=$W_GAPS; line with the thought under it=$W_HELD"
expect_watch "short"
short="$(wait_summaries 20 "$S153S" 1)" || fail "the short session's turn never finished"
# Settled, the box is flush at the bottom: nothing lingered past the turn.
footer_row="$(printf '%s\n' "$short" | grep -nF 'dummy_model_name ·' | tail -1 | cut -d: -f1)"
expect_eq "${footer_row:-0}" "16" "the settled box is not on the bottom row: a row outlived the turn"
expect_eq "$(count_footers "$short")" "1" "the settled short session shows the footer more than once"
keys "$S153S" C-c
wait_gone 10 "$S153S" || fail "the short session did not quit on Ctrl+C"

# ---- the real backend against a paced stub provider ------------------------
# The dummy scripts its events; these turns go through `LlmBackend` and
# `stream_round` the way a provider's stream does. The stub picks its script
# by the user's message:
#   "list the files" — a fast model's shape: a three-line thought, then a
#     `bash` call whose arguments stream in about 0.2 s, well inside the
#     linger, and a second round two seconds later. Settled at once, the
#     block left a hole that long under the status line.
#   "run the command" — a three-line thought, then a `bash` call whose
#     arguments stream over about a second, longer than the linger, a
#     command whose tailing cell stands taller than its settled peek, and a
#     three-second wait before the second round (the round boundary the
#     reported blank rows sat in).
#   "plan the work" — a thought, then only a `taskcreate`, which records no
#     cell, and a next request that fails with a 500 once before it answers.
#     A thought line once went missing here, dropped by the retry as though
#     the failed attempt had produced it.
SR_PORT="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 - "$SR_PORT" <<'PY' &
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

port = int(sys.argv[1])
failed = set()  # the scripts whose second round has failed once already

def said(messages):
    """Every user-role text of the request, joined."""
    out = []
    for message in messages:
        if message.get("role") != "user":
            continue
        content = message.get("content")
        if isinstance(content, str):
            out.append(content)
        elif isinstance(content, list):
            out.extend(part.get("text", "") for part in content if isinstance(part, dict))
    return "\n".join(out)

class Stub(BaseHTTPRequestHandler):
    def do_GET(self):
        data = b'{"object":"list","data":[{"id":"stub-model"}]}'
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def emit(self, delta, pause=0.0, finish=None):
        choice = {"delta": delta}
        if finish:
            choice["finish_reason"] = finish
        self.wfile.write(("data: %s\n\n" % json.dumps({"choices": [choice]})).encode())
        self.wfile.flush()
        time.sleep(pause)

    def think(self, lines):
        for line in lines:
            self.emit({"reasoning_content": line}, 0.15)

    def call(self, name, args, pause):
        # The thought settles on the first piece; the call is announced only
        # once the last one is in.
        pieces = [args[i:i + 12] for i in range(0, len(args), 12)]
        self.emit({"tool_calls": [{"index": 0, "id": "call_153", "type": "function",
                                   "function": {"name": name, "arguments": pieces[0]}}]}, pause)
        for piece in pieces[1:]:
            self.emit({"tool_calls": [{"index": 0, "function": {"arguments": piece}}]}, pause)
        self.emit({}, finish="tool_calls")

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("content-length") or 0)))
        messages = body.get("messages", [])
        text = said(messages)
        script = "plan" if "plan the work" in text else "list" if "list the files" in text else "run"
        first_round = messages[-1].get("role") == "user"
        if script == "plan" and not first_round and script not in failed:
            failed.add(script)
            data = b'{"error":{"message":"stub overloaded","type":"server_error"}}'
            self.send_response(500)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        # HTTP/1.0 with no length: the stream ends when the connection does,
        # so each frame reaches the client as it is written.
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.end_headers()
        if first_round and script == "list":
            self.think(["Let me list the files first.\n", "One command does it.\n",
                        "Then I can count them.\n"])
            self.call("bash", json.dumps({"command": "ls -la", "description": "List the files"}), 0.04)
        elif first_round and script == "run":
            self.think(["Let me run the command first.\n", "It prints thirty lines.\n",
                        "Then I can answer.\n"])
            command = "for i in $(seq 1 30); do echo line-$i; sleep 0.05; done"
            self.call("bash", json.dumps({"command": command, "description": "Print thirty lines"}), 0.12)
        elif first_round:
            self.think(["Plan the work before doing it.\n", "One task covers it.\n"])
            self.call("taskcreate", json.dumps({"subject": "Count the lines",
                                                "description": "Count them"}), 0.0)
        else:
            if script == "run":
                time.sleep(3)  # the next round's wait: what the reported screen showed
            elif script == "list":
                time.sleep(2)  # long enough to sample the call's cell
            self.emit({"content": "Done."})
            self.emit({}, finish="stop")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def log_message(self, *_args):
        pass

ThreadingHTTPServer(("127.0.0.1", port), Stub).serve_forever()
PY
SR_STUB=$!
smoke_on_exit kill "$SR_STUB"
for _ in $(seq 1 30); do # wait for the stub to listen
	if python3 -c "import socket, sys; s = socket.socket(); s.settimeout(0.2); sys.exit(0 if s.connect_ex(('127.0.0.1', $SR_PORT)) == 0 else 1)" 2>/dev/null; then
		break
	fi
	sleep 0.1
done
SR_PROVIDERS="$SMOKE_TMP/providers153.toml"
printf '[providers.stub]\nname = "Stub"\n\n[providers.stub.kwargs]\napi_base = "http://127.0.0.1:%s/v1"\n' "$SR_PORT" >"$SR_PROVIDERS"
# Master mode: the command runs unasked, so nothing but the strip is on screen.
SR_APP="env NO_PROXY=127.0.0.1 no_proxy=127.0.0.1 $CFG_ENV_NOHIST ALTER_ZERO_PERMISSION_MODE=master ALTER_ZERO_PROVIDERS_FILE=$SR_PROVIDERS ALTER_ZERO_PROVIDER=stub ALTER_ZERO_MODEL=stub-model STUB_API_KEY=stand-in $BIN_ABS"

# ---- 3. "list the files": a call written inside the linger ------------------
# A fast model's hand-off: the block must give its rows straight to the
# call's cell, so the box never rises — and since the call lands inside the
# linger, no sample may show the settled line without it. The live cell's
# bullet blinks, so its header is matched without it (docs/tool-pulse.md).
S153Q="${S}_thoughthandoffquick"
launch -c "$(work_dir quick)" "$S153Q" 100 30 "$SR_APP"
submit "$S153Q" "list the files"
watch_turn "$S153Q" 'stub-model ·' "Let me list the files first." "Bash("
note "quick call: sampled $W_SAMPLES times; rises before the cell=$W_HOPS; held gaps=$W_GAPS; line with the thought under it=$W_HELD; line alone before the cell=$W_ALONE"
expect_watch "quick call" still
if [ "$W_ALONE" -ne 0 ]; then
	fail "quick call: a sample showed the settled line before the call's cell, though the call landed inside the linger: the block gave its rows up early"
fi
quick="$(wait_pane 20 "$S153Q" -S -60 -- -F "Done.")" || fail "the quick call's second round never answered"
dump "the settled quick-call session" "$quick"
expect_eq "$(grep -cE '^Thought for [0-9]+s' <<<"$quick")" "1" \
	"the quick call's thought did not settle into exactly one 'Thought for' line"
expect_eq "$(grep -cF '● Bash(ls -la)' <<<"$quick")" "1" "the quick call is not there exactly once"
expect_lacks "$quick" -F "Let me list the files first." "the quick call's thought reached the conversation: only its line may commit"
keys "$S153Q" C-c
wait_gone 10 "$S153Q" || fail "the quick-call session did not quit on Ctrl+C"

# ---- 4. "run the command": a call written over about a second ---------------
# Longer than the linger: the block gives way to the settled line ALONE —
# never a block still saying the model thinks, never the line over the
# thought — and the call's cell lands under it later. The blank-row rule
# holds throughout: the call being written, and the round boundary.
S153R="${S}_thoughthandoffreal"
launch -c "$(work_dir real)" "$S153R" 100 30 "$SR_APP"
submit "$S153R" "run the command"
watch_turn "$S153R" 'stub-model ·' "Let me run the command first." "Bash("
note "slow call: sampled $W_SAMPLES times; rises before the cell=$W_HOPS; held gaps=$W_GAPS; line with the thought under it=$W_HELD; line alone before the cell=$W_ALONE"
expect_watch "slow call"
if [ "$W_ALONE" -ne 1 ]; then
	fail "slow call: no sample showed the settled line on its own while the call was still being written: the block outlived its linger"
fi
real="$(wait_pane 20 "$S153R" -S -60 -- -F "Done.")" || fail "the stub's second round never answered"
dump "the settled slow-call session" "$real"
expect_eq "$(grep -cE '^Thought for [0-9]+s' <<<"$real")" "1" \
	"the stub's thought did not settle into exactly one 'Thought for' line"
expect_eq "$(grep -cF '● Bash(for i in' <<<"$real")" "1" "the stub's call is not there exactly once"
expect_lacks "$real" -F "Let me run the command first." "the stub's thought reached the conversation: only its line may commit"
keys "$S153R" C-c
wait_gone 10 "$S153R" || fail "the real-backend session did not quit on Ctrl+C"

# ---- 5. "plan the work": a thought, a task call with no cell, a retry -------
S153T="${S}_thoughthandofftask"
launch -c "$(work_dir task)" "$S153T" 100 30 "$SR_APP"
submit "$S153T" "plan the work"
wait_pane 25 "$S153T" -S -60 -- -F "Done." >/dev/null || fail "the retried second round never answered"
task="$(wait_settled 5 "$S153T" -S -60 -- -E "^$SUMMARY_RE")"
dump "the settled task-call session" "$task"
expect_has "$task" -F "Count the lines" "the task call never reached the checklist"
expect_eq "$(grep -cE '^Thought for [0-9]+s' <<<"$task")" "1" \
	"the thought before the task call lost its line, or landed twice: it must commit exactly once, whatever the retry does"
keys "$S153T" C-c
wait_gone 10 "$S153T" || fail "the task-call session did not quit on Ctrl+C"
