#!/usr/bin/env python3
"""Bounds sensor: asks TypeSafe three closed questions about each changed Elixir
function that reads, buffers, waits, or queues. Its flags are targets for the
failure-path reviewer. It never passes or fails a change, so every problem is
one printed line and exit status 0.

  bounds_sensor.py --diff <base>              functions the working tree changed, under lib/
  bounds_sensor.py --commit <rev> <file>...   every candidate function at a revision (to re-measure)
"""
import json, os, re, stat, subprocess, sys, urllib.request
from concurrent.futures import ThreadPoolExecutor

MODEL = "jev-latest"
# Measured on master at 93c33e9, 2026-09-18: 0.9 gave 12 flags, 9 true. 0.7 also
# caught two known defects that 0.9 missed, and doubled the flags.
THRESHOLD = 0.9
MAX_BYTES = 1_000_000  # one source file, and one API response
NO_ANSWER = "NO ANSWER"
DEF = re.compile(r"\s+def(p|macro|macrop)? ")
# A cost filter only: constructs the review checklist cares about.
CANDIDATE = re.compile(r"File\.read|File\.stream|IO\.(bin)?read|receive\b|:infinity|Port\.|\{:data,|<>|\+\+|:queue\.|Enum\.into|Req\.|into:|\bacc\b|buffer|Process\.sleep|GenServer\.call|Task\.(await|yield)|\[.*\|")
INTRO = "This is one Elixir function. "
QUESTIONS = {
    "growth": {"type": "choice",
        "instructions": INTRO + "Does it read, receive, or accumulate data whose size an outside party controls (a file, a network response, a subprocess, a user, a model)?",
        "criteria": {"yes": "It reads, receives, or accumulates externally controlled data",
                     "no": "It only transforms values already in memory, or handles fixed-size data"}},
    "limit": {"type": "choice",
        "instructions": INTRO + "What limits the amount of data it reads, receives, or accumulates?",
        "criteria": {
            "explicit cap": "The function compares a size, length, or count against a named limit, or reads at most a fixed number of bytes or lines",
            "no limit visible": "Data is read, received, or accumulated and nothing shown checks or caps the size",
            "not applicable": "The function does not read, receive, or accumulate data"}},
    "wait": {"type": "choice",
        "instructions": INTRO + "If it waits for a message, a call reply, or an external event, what ends the wait when nothing arrives?",
        "criteria": {
            "timeout or monitor": "A finite timeout, an `after` clause, or a monitor or link ends the wait",
            "can wait forever": "It waits with `:infinity` or with a `receive` that has no `after`, and nothing else ends the wait",
            "does not wait": "The function does not wait for anything"}}}


def say(line):
    """Every printed line goes through here. Escaped to ASCII: a newline in a name
    or a revision cannot forge a second line, and no character can fail to encode.
    A backslash in the text prints doubled."""
    try:
        print(line.encode("unicode_escape").decode(), flush=True)  # flush: a write error must surface here, not at exit
    except BrokenPipeError:  # the reader left; nobody to tell
        pass
    except OSError as error:  # a full disk, say: the lines after this one would be lost in silence
        try:
            print(f"bounds sensor failed: output lost: {error}", file=sys.stderr)
        finally:
            os._exit(0)


def git(*args):
    """Bytes: text mode turns a lone "\r" into "\n", which renames files and shifts lines."""
    done = subprocess.run(["git", *args], capture_output=True)
    if done.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)}: {(done.stderr.decode(errors='replace').strip().splitlines() or [done.returncode])[0]}")
    return done.stdout


def text(data):
    """The size limit is on bytes, before the decode: a character count lets a
    multibyte file through, cut short."""
    if len(data) > MAX_BYTES:
        raise RuntimeError(f"over {MAX_BYTES} bytes")
    return data.decode(errors="replace")


def functions(source):
    """[(first_line, last_line, text)]. A clause runs from an indented def line to
    the next one. Crude on purpose: a `def` line inside a heredoc becomes a
    clause, which costs one extra question. Lines split on "\n" only, as git
    counts them; splitlines() also splits on U+2028 and shifts every number."""
    out, start, clause = [], 0, []
    for number, line in enumerate(source.split("\n"), 1):
        if DEF.match(line):
            if clause:
                out.append((start, number - 1, "\n".join(clause)))
            start, clause = number, [line]
        elif clause:
            clause.append(line)
    if clause:
        out.append((start, start + len(clause) - 1, "\n".join(clause)))
    return out


def changed_lines(base, path):
    """--text: a NUL byte makes git call the file binary and print no hunks."""
    lines = set()
    for hunk in re.finditer(rb"^@@ .*?\+(\d+)(?:,(\d+))? @@", git("diff", "--text", "--no-color", "--no-ext-diff", "-U0", base, "--", path), re.M):
        first, count = int(hunk.group(1)), int(hunk.group(2) or 1)
        lines.update(range(first, first + max(count, 1)))  # ,0 is a pure deletion: mark the line git names, the one before it
    return lines


def flags_of(answers):
    """Raises on any answer that does not have the shape asked for: a lenient
    read turns a malformed answer into a clean result."""
    for q, question in QUESTIONS.items():
        confidence = answers[q]["confidence"]
        if answers[q]["choice"] not in question["criteria"] or type(confidence) not in (int, float) \
                or not 0 <= confidence <= 1:  # NaN fails the comparison too
            raise ValueError(f"unexpected answer to {q}: {answers[q]!r:.80}")
    sure = lambda q, value: answers[q]["choice"] == value and answers[q]["confidence"] >= THRESHOLD
    flags = []
    if sure("growth", "yes") and sure("limit", "no limit visible"):
        flags.append("SIZE")
    if sure("wait", "can wait forever"):
        flags.append("WAIT")
    return flags


def ask(item):
    """One request per function, so one bad function (over the 32k-token state
    limit, say) loses only its own answer."""
    path, first, state = item
    if first == 0:  # candidates() could not read the file; state is the reason
        return path, first, "whole file", [f"{NO_ANSWER} ({state})"]
    head = state.strip().split("\n")[0][:60]
    try:
        body = json.dumps({"state": state, "model": MODEL, "questions": QUESTIONS}).encode()
        request = urllib.request.Request("https://api.typesafe.ai/v1/systemone", body, {
            "Authorization": "Bearer " + os.environ["TYPESAFE_API_KEY"],
            "Content-Type": "application/json", "User-Agent": "helyx-bounds-sensor"})
        # ponytail: the timeout is per socket read, so a slow-drip server can hold a
        # thread longer. Worst honest case is len(items) / 8 * 20 s, connect plus one read. Add a total
        # deadline if the API host ever proves unreliable.
        with urllib.request.urlopen(request, timeout=10) as response:
            answers = json.loads(response.read(MAX_BYTES))["answers"]
        return path, first, head, flags_of(answers)
    except Exception as error:  # includes an answer with an unexpected shape
        return path, first, head, [f"{NO_ANSWER} ({error!r})"]


def read_source(path):
    """The text goes to an outside service: only a regular file whose real path
    is inside the repo, and at most MAX_BYTES of it. The type check and the read
    use one descriptor. ponytail: the real path check uses the path, so a parent
    directory swapped for a symlink between that check and the open gets through.
    That needs a hostile process in the user's own checkout; use openat per
    component if the sensor ever runs on a tree someone else can write."""
    if not os.path.realpath(path).startswith(os.getcwd() + os.sep):
        raise RuntimeError("real path is outside the repo")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise RuntimeError("not a regular file")
        data = os.read(fd, MAX_BYTES + 1)
    finally:
        os.close(fd)
    return text(data)


def candidates(path, read, lines=None):
    """`read` returns the source. A file that cannot be read costs only itself."""
    try:
        source = read()
    except Exception as error:
        return [(path, 0, str(error))]
    return [(path, first, clause) for first, last, clause in functions(source)
            if CANDIDATE.search(clause) and (lines is None or lines & set(range(first, last + 1)))]


def main(argv):
    if "TYPESAFE_API_KEY" not in os.environ:
        return say("bounds sensor skipped: TYPESAFE_API_KEY is not set")
    if len(argv) < 2 or argv[0] not in ("--diff", "--commit") or (argv[0] == "--commit" and len(argv) < 3):
        return say("bounds sensor failed: usage: --diff <base> | --commit <rev> <file>...")
    if argv[1].startswith("-"):
        return say("bounds sensor failed: a revision cannot start with '-'")  # git would take it as an option
    os.chdir(os.fsdecode(git("rev-parse", "--show-toplevel")).strip())  # git prints paths relative to the root
    # lexists: a deleted file has no functions to ask about; a dangling symlink must reach read_source.
    is_source = lambda p: re.search(r"(^|/)lib/.*\.ex$", p, re.S) and os.path.lexists(p)
    names = lambda *args: [os.fsdecode(p) for p in git(*args, "-z").split(b"\0") if p]  # -z: no quoting of odd names
    items = []
    if argv[0] == "--diff":
        for path in filter(is_source, names("diff", "--name-only", argv[1])):
            items += candidates(path, lambda: read_source(path), changed_lines(argv[1], path))
        for path in filter(is_source, names("ls-files", "--others", "--exclude-standard")):
            items += candidates(path, lambda: read_source(path))  # git diff does not list an untracked file
    else:
        for path in argv[2:]:
            items += candidates(path, lambda: text(git("cat-file", "blob", f"{argv[1]}:{path}")))  # fails on a tree or a gitlink; show does not
    with ThreadPoolExecutor(8) as pool:
        results = list(pool.map(ask, items))
    failed = sum(any(f.startswith(NO_ANSWER) for f in flags) for *_, flags in results)
    flagged = sum(bool(flags) for *_, flags in results) - failed
    say(f"bounds sensor: {len(items)} candidate functions, {flagged} flagged, {failed} without an answer")
    for path, first, head, flags in results:
        if flags:
            say(f"  {path}:{first}  {'+'.join(flags)}  {head}")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Exception as error:  # a git failure or a bad ref must not stop a ship run
        say(f"bounds sensor failed: {error}")
    try:
        sys.stdout.flush()
    except Exception:  # a reader that left early (`| head`) or a closed stdout must not change the exit status
        os.dup2(os.open(os.devnull, os.O_WRONLY), 1)
