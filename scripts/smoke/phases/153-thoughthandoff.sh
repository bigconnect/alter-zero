#!/usr/bin/env bash
# Phase 153 — a thought settles in the frame its round's next cell lands, as one line with nothing under it

. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
smoke_begin

# THE THOUGHT HAND-OFF (docs/thought-handoff.md). The backend ends a thinking
# phase at the round's first tool-call piece, but the call has a cell only
# once its batch is announced. Collapsing the `● Thinking…` block at that
# piece lifted the box by the block's rows until the cell landed a few frames
# later, then dropped it back: the flicker reported between a quick think and
# a tool call. The block now stays up through a short settle grace
# (THOUGHT_SETTLE_GRACE, a second): whatever draws or records next settles
# it, the `Thought for …` line committing in the same frame the next cell
# lands on the block's rows, and past the grace it settles anyway.
#
# What the settled line must never be is the hold this replaced: the
# `Thought for …` line over a tail of the thought, left on screen until the
# next cell landed — for as long as a slow call took to generate. A thought
# shows as the live block or as its one line, never both. And mid-turn the
# status line has exactly ONE blank row above it (the first fix held blank
# rows instead, three empty lines over the status line between rounds).
#
# Each turn is sampled ~20 times a second, each candidate confirmed against a
# second capture a beat later (Phase 121's rule: a torn frame lasts
# microseconds, a hop or a held gap as long as it is held). Four turns:
#   1. the REAL backend against a paced stub provider: a thought, blank
#      content, then a call written over ~480 ms, inside the grace — a live
#      model's hand-off to a long command (measured: a call's arguments finish
#      17–120 ms after a short call's thought ends, 406–642 ms after one
#      carrying a long path) — on a terminal with room below the box, and
#      again on a short one where the box sits on the bottom row: no hop;
#   2. the same backend with a call written over about two and a half
#      seconds, longer than the grace: the block settles before the call's
#      cell lands, and the three-second round boundary after it holds one
#      blank row;
#   3. a thought whose round records only a task call, then a retried
#      request: its line still reaches scrollback exactly once;
#   4. the offline dummy turn, whose three scripted calls take ~765 ms to
#      "generate": no hop, its line and cells exactly once, no purge rebuild.

# The blank rows directly above the status line in a capture, or nothing when
# no status line is on screen.
gap_above_status() {
	printf '%s\n' "$1" | awk '
		/esc to interrupt/ { print blank; exit }
		/^[[:space:]]*$/ { blank++; next }
		{ blank = 0 }'
}

# watch_turn SESSION FOOTER THOUGHT [CELL] — sample a turn until its status
# line goes; sets W_SAMPLES, W_BLOCK (a sample showed THOUGHT in the live
# block), W_TAIL (confirmed samples showing the settled line with THOUGHT
# still on screen), W_EARLY (a confirmed sample showed the settled line
# before CELL landed — matched without its bullet, which blinks), W_HOPS (confirmed rises of the FOOTER row while the status line was
# up — none counted once a sample shows CELL, whose round's end may lift the
# box) and W_GAPS (confirmed samples with more than one blank row above the
# status line).
watch_turn() {
	local sess="$1" footer="$2" thought="$3" cell="${4:-}" vis again now prev=0 seen=0 gap landed=0
	W_SAMPLES=0
	W_BLOCK=0
	W_TAIL=0
	W_EARLY=0
	W_HOPS=0
	W_GAPS=0
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
		if [ -n "$cell" ] && printf '%s' "$vis" | grep -qF "$cell"; then
			landed=1
		fi
		if printf '%s' "$vis" | grep -qF "$thought"; then
			W_BLOCK=1
		fi
		if printf '%s' "$vis" | grep -qE '^Thought for [0-9]+s'; then
			if [ "$landed" -eq 0 ] && [ "$W_EARLY" -eq 0 ]; then
				sleep 0.03
				again="$(tmux capture-pane -t "$sess" -p)"
				if printf '%s' "$again" | grep -qE '^Thought for [0-9]+s' &&
					{ [ -z "$cell" ] || ! printf '%s' "$again" | grep -qF "$cell"; }; then
					W_EARLY=1
				fi
			fi
			if printf '%s' "$vis" | grep -qF "$thought"; then
				sleep 0.03
				again="$(tmux capture-pane -t "$sess" -p)"
				if printf '%s' "$again" | grep -qE '^Thought for [0-9]+s' &&
					printf '%s' "$again" | grep -qF "$thought"; then
					W_TAIL=$((W_TAIL + 1))
					if [ "$W_TAIL" -le 2 ]; then
						dump "$sess: the settled line shares the screen with the thought it settled (sample $W_SAMPLES)" "$again"
					fi
				fi
			fi
		fi
		now=$(printf '%s\n' "$vis" | grep -nF "$footer" | tail -1 | cut -d: -f1)
		if [ "${now:-0}" -gt 0 ] && [ "$now" -lt "$prev" ] && [ "$landed" -eq 0 ]; then
			sleep 0.03
			again="$(tmux capture-pane -t "$sess" -p)"
			local now_again
			now_again=$(printf '%s\n' "$again" | grep -nF "$footer" | tail -1 | cut -d: -f1)
			if printf '%s' "$again" | grep -qF "esc to interrupt" &&
				{ [ -z "$cell" ] || ! printf '%s' "$again" | grep -qF "$cell"; } &&
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
	note "$sess: sampled $W_SAMPLES times; block seen=$W_BLOCK; tails=$W_TAIL; settled before the cell=$W_EARLY; hops=$W_HOPS; held gaps=$W_GAPS"
}

# expect_settles WHAT — the verdicts every turn owes: the block was seen
# (liveness: a quiet watch is a real pass), the settled line never had the
# thought on screen with it, and one blank row above the status line.
expect_settles() {
	if [ "$W_BLOCK" -ne 1 ]; then
		fail "$1: no sample showed the thought in its live block: the watch never reached the hand-off"
	fi
	if [ "$W_TAIL" -ne 0 ]; then
		fail "$1: $W_TAIL sample(s) showed the settled 'Thought for' line with the thought still on screen: a thought is its live block or its one line, never both (see the frames above)"
	fi
	if [ "$W_GAPS" -ne 0 ]; then
		fail "$1: $W_GAPS sample(s) held more than one blank row above the status line (see the frames above)"
	fi
}

# expect_no_hop WHAT — the hand-off kept the box still until the cell landed.
expect_no_hop() {
	if [ "$W_HOPS" -ne 0 ]; then
		fail "$1: the box hopped up $W_HOPS time(s) before the call's cell landed: the thought gave its rows up before the cell could take them (see the frames above)"
	fi
	if [ "$W_EARLY" -ne 0 ]; then
		fail "$1: a sample showed the settled line before the call's cell: the block collapsed without waiting for it"
	fi
}

# ---- the real backend against a paced stub provider ------------------------
# These turns go through `LlmBackend` and `stream_round` the way a provider's
# stream does. The stub picks its script by the user's message:
#   "answer quickly" — a six-line thought, blank content, then a `bash` call
#     whose arguments are all in ~480 ms after the thought's end (inside the
#     grace), a command that takes a second, and a second's wait before the
#     answer.
#   "run the command" — a three-line thought, then a `bash` call whose
#     arguments stream over about two and a half seconds, a command whose
#     tailing cell
#     stands taller than its settled peek, and a three-second wait before the
#     second round (the round boundary the reported blank rows sat in).
#   "plan the work" — a thought, then only a `taskcreate`, which records no
#     cell, and a next request that fails with a 500 once before it answers.
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
        # The thought ends at the first piece; the call is announced only once
        # the last one is in.
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
        script = "plan" if "plan the work" in text else "quick" if "answer quickly" in text else "run"
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
        if first_round and script == "quick":
            self.think(["Answer it quickly.\n", "One short command does it.\n",
                        "It waits a second first.\n", "Then it prints a word.\n",
                        "Then say it is done.\n", "Nothing more to plan.\n"])
            # Some models send blank content between the thought and the call:
            # it puts nothing in the strip, so it must not end the wait.
            self.emit({"content": "\n\n"})
            # Written over ~480 ms, like a live call carrying a long path:
            # inside the grace, and long enough that a block collapsing at
            # the thought's end shows the hop to the watch.
            self.call("bash", json.dumps({"command": "sleep 1; echo ready-153"}), 0.12)
        elif first_round and script == "run":
            self.think(["Let me run the command first.\n", "It prints thirty lines.\n",
                        "Then I can answer.\n"])
            command = "for i in $(seq 1 30); do echo line-$i; sleep 0.05; done"
            self.call("bash", json.dumps({"command": command, "description": "Print thirty lines"}), 0.25)
        elif first_round:
            self.think(["Plan the work before doing it.\n", "One task covers it.\n"])
            self.call("taskcreate", json.dumps({"subject": "Count the lines",
                                                "description": "Count them"}), 0.0)
        else:
            if script == "run":
                time.sleep(3)  # the next round's wait: what the reported screen showed
            elif script == "quick":
                time.sleep(1)
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
# The thought's last line: the block shows its last three rows, so this is
# the one row of it that is always on screen while it is.
QUICK_THOUGHT="Nothing more to plan."

# ---- 1. "answer quickly": a live model's hand-off, at two sizes -------------
for size in "100 30" "80 16"; do
	set -- $size
	S153Q="${S}_thoughthandoffquick$1x$2"
	RAW153Q="$SMOKE_TMP/phase153quick$1x$2.raw"
	launch -c "$(work_dir "quick$1x$2")" "$S153Q" "$1" "$2" "$SR_APP"
	tmux pipe-pane -t "$S153Q" -o "cat > $RAW153Q"
	submit "$S153Q" "answer quickly"
	watch_turn "$S153Q" 'stub-model ·' "$QUICK_THOUGHT" "echo ready-153)"
	expect_settles "quick $1x$2"
	expect_no_hop "quick $1x$2"
	quick="$(wait_pane 20 "$S153Q" -S -60 -- -F "Done.")" || fail "quick $1x$2: the stub's second round never answered"
	tmux pipe-pane -t "$S153Q" # close the recording before quitting
	dump "the settled quick session ($1x$2)" "$quick"
	expect_eq "$(grep -cE '^Thought for [0-9]+s' <<<"$quick")" "1" \
		"quick $1x$2: the thought did not settle into exactly one 'Thought for' line"
	expect_has "$quick" -E "^Thought for [0-9]+s · [0-9]+ tokens \(ctrl\+o to expand\)$" \
		"quick $1x$2: the settled line is not the plain 'Thought for Ns · N tokens (ctrl+o to expand)'"
	expect_lacks "$quick" -F "$QUICK_THOUGHT" "quick $1x$2: the thought's own text reached the conversation: only its line may commit"
	# The line sits straight over the call it handed off to, one spacer between:
	# the blank content the model sent is no row of its own.
	expect_eq "$(grep -A 2 -E '^Thought for [0-9]+s' <<<"$quick" | sed -n 3p | grep -cF 'echo ready-153)')" "1" \
		"quick $1x$2: the call's cell is not one spacer under the thought's line"
	expect_eq "$(grep -cF 'echo ready-153)' <<<"$quick")" "1" "quick $1x$2: the call's cell is not there exactly once"
	purges=$(grep -c $'\x1b\\[3J' "$RAW153Q" 2>/dev/null || true)
	expect_eq "${purges:-0}" "0" "quick $1x$2: the turn purge-rebuilt the screen"
	keys "$S153Q" C-c
	wait_gone 10 "$S153Q" || fail "quick $1x$2: the session did not quit on Ctrl+C"
done

# ---- 2. "run the command": a call slower than the grace, then a slow round --
S153R="${S}_thoughthandoffreal"
launch -c "$(work_dir real)" "$S153R" 100 30 "$SR_APP"
submit "$S153R" "run the command"
# Only a rise before the call's cell is the hand-off's — and this call is
# written over about two and a half seconds, so the grace runs out first: the
# block settles into its line on its own, and the box may rise until the cell
# lands. The blank-row rule holds throughout, the round boundary included.
watch_turn "$S153R" 'stub-model ·' "Let me run the command first." "Bash(for i in"
expect_settles "slow call"
if [ "$W_EARLY" -ne 1 ]; then
	fail "slow call: no sample showed the settled line before the call's cell: the block waited out the whole call instead of its grace"
fi
real="$(wait_pane 20 "$S153R" -S -60 -- -F "Done.")" || fail "the stub's second round never answered"
dump "the settled slow-call session" "$real"
expect_eq "$(grep -cE '^Thought for [0-9]+s' <<<"$real")" "1" \
	"slow call: the thought did not settle into exactly one 'Thought for' line"
expect_eq "$(grep -cF '● Bash(for i in' <<<"$real")" "1" "slow call: the call is not there exactly once"
expect_lacks "$real" -F "Let me run the command first." "slow call: the thought reached the conversation: only its line may commit"
keys "$S153R" C-c
wait_gone 10 "$S153R" || fail "the slow-call session did not quit on Ctrl+C"

# ---- 3. "plan the work": a thought, a task call with no cell, a retry -------
S153T="${S}_thoughthandofftask"
launch -c "$(work_dir task)" "$S153T" 100 30 "$SR_APP"
submit "$S153T" "plan the work"
wait_pane 25 "$S153T" -S -60 -- -F "Done." >/dev/null || fail "the retried second round never answered"
task="$(wait_settled 5 "$S153T" -S -60 -- -E "^$SUMMARY_RE")"
dump "the settled task-call session" "$task"
expect_has "$task" -F "Count the lines" "the task call never reached the checklist"
expect_eq "$(grep -cE '^Thought for [0-9]+s' <<<"$task")" "1" \
	"the thought before the task call did not reach scrollback exactly once through the retry"
keys "$S153T" C-c
wait_gone 10 "$S153T" || fail "the task-call session did not quit on Ctrl+C"

# ---- 4. the offline dummy turn ----------------------------------------------
S153D="${S}_thoughthandoffdummy"
RAW153D="$SMOKE_TMP/phase153dummy.raw"
THOUGHT153="Let me read the file first."
launch "$S153D" 80 24
tmux pipe-pane -t "$S153D" -o "cat > $RAW153D"
submit "$S153D" "$USER_MSG"
watch_turn "$S153D" 'dummy_model_name ·' "$THOUGHT153" "Read(about.py)"
expect_settles "dummy"
expect_no_hop "dummy"
wait_summaries 20 "$S153D" 1 >/dev/null || fail "the default turn never finished"
tmux pipe-pane -t "$S153D" # close the recording before quitting
final="$(pane "$S153D" -S -200)"
dump "captured pane + scrollback (the settled dummy turn)" "$final"
expect_eq "$(grep -cE '^Thought for [0-9]+s' <<<"$final")" "1" \
	"dummy: the thought did not settle into exactly one 'Thought for' line"
expect_lacks "$final" -F "$THOUGHT153" "dummy: the thought's own text reached the conversation: only its line may commit"
expect_eq "$(grep -cF '● Read(about.py)' <<<"$final")" "1" "dummy: the read's cell is not there exactly once"
expect_eq "$(grep -cF '● Edit(about.py)' <<<"$final")" "1" "dummy: the edit's cell is not there exactly once"
expect_eq "$(grep -cF '● Bash(python3 about.py)' <<<"$final")" "1" "dummy: the run's cell is not there exactly once"
purges=$(grep -c $'\x1b\\[3J' "$RAW153D" 2>/dev/null || true)
expect_eq "${purges:-0}" "0" "dummy: the turn purge-rebuilt the screen"
keys "$S153D" C-c
wait_gone 10 "$S153D" || fail "the dummy session did not quit on Ctrl+C"
