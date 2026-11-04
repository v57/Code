#!/usr/bin/env python3
"""Times any language server over stdio with the same requests, and saves its answers.

    lspbench.py --root <folder> --out <json> [--wait-index] [--samples N] -- <server command...>

The positions come from a seeded random pick of identifiers in the root's sources (`--ext`), so two servers answer the
same questions and `--compare a.json b.json` can tell how often the answers agree.
"""
import argparse, json, os, random, re, resource, select, subprocess, sys, time
from urllib.parse import quote, unquote

SKIP = {".build", ".git", "node_modules", "target", "build", "DerivedData", ".swiftpm", "dist", "vendor"}
IDENT = re.compile(r"\b[A-Za-z_][A-Za-z0-9_]{2,}\b")
NOISE = re.compile(r"^\s*(//|#|\*|/\*)")


class Server:
    def __init__(self, command, cwd, env):
        self.process = subprocess.Popen(
            command, cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.buffer = bytearray()
        self.next_id = 1
        self.progress = {}
        self.progress_seen = False
        self.progress_last_end = None
        self.diagnostics = {}

    def send(self, message):
        body = json.dumps(message).encode()
        self.process.stdin.write(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        self.process.stdin.flush()

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def _read(self, timeout):
        deadline = time.monotonic() + timeout
        fd = self.process.stdout.fileno()
        while True:
            end = self.buffer.find(b"\r\n\r\n")
            if end >= 0:
                header = bytes(self.buffer[:end]).lower()
                length = int(re.search(rb"content-length: *(\d+)", header).group(1))
                if len(self.buffer) >= end + 4 + length:
                    body = bytes(self.buffer[end + 4 : end + 4 + length])
                    del self.buffer[: end + 4 + length]
                    return json.loads(body)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            ready, _, _ = select.select([fd], [], [], remaining)
            if not ready:
                return None
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                raise EOFError("server exited")
            self.buffer += chunk

    def _handle(self, message):
        if "method" in message and "id" in message:  # A request from the server.
            result = None
            if message["method"] == "workspace/configuration":
                result = [None for _ in message["params"]["items"]]
            self.send({"jsonrpc": "2.0", "id": message["id"], "result": result})
        elif message.get("method") == "$/progress":
            token, value = str(message["params"]["token"]), message["params"]["value"]
            if value.get("kind") == "begin":
                self.progress[token] = value.get("title", "")
                self.progress_seen = True
            elif value.get("kind") == "end":
                self.progress.pop(token, None)
                self.progress_last_end = time.monotonic()
        elif message.get("method") == "textDocument/publishDiagnostics":
            self.diagnostics[message["params"]["uri"]] = message["params"]["diagnostics"]

    def request(self, method, params, timeout=120):
        id_ = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": id_, "method": method, "params": params})
        deadline = time.monotonic() + timeout
        while True:
            message = self._read(max(0.0, deadline - time.monotonic()))
            if message is None:
                return "timeout"
            if message.get("id") == id_ and "method" not in message:
                if "error" in message:
                    return {"error": message["error"].get("message", "")}
                return message.get("result")
            self._handle(message)

    def drain(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            message = self._read(deadline - time.monotonic())
            if message is None:
                return
            self._handle(message)

    def wait_index(self, quiet, limit):
        """Until no progress is open and none began for `quiet` seconds."""
        start = time.monotonic()
        while time.monotonic() - start < limit:
            self.drain(0.5)
            if self.progress:
                continue
            last = self.progress_last_end
            if self.progress_seen and last and time.monotonic() - last > quiet:
                return time.monotonic() - start - quiet
            if not self.progress_seen and time.monotonic() - start > max(quiet, 20):
                return None
        return float("inf")

    def rss_mb(self):
        out = subprocess.run(["ps", "-o", "rss=", "-p", str(self.process.pid)], capture_output=True, text=True).stdout
        return int(out.strip() or 0) / 1024


def sources(root, extensions):
    found = []
    for folder, dirs, files in os.walk(root):
        dirs[:] = sorted(d for d in dirs if d not in SKIP and not d.startswith("."))
        for name in sorted(files):
            if os.path.splitext(name)[1].lstrip(".") in extensions:
                found.append(os.path.join(folder, name))
    return found


def sample(paths, count, seed):
    random.seed(seed)
    picks = []
    pool = paths[:]
    random.shuffle(pool)
    while pool and len(picks) < count:
        path = pool.pop()
        with open(path, encoding="utf-8", errors="replace") as file:
            lines = file.read().split("\n")
        candidates = [
            (index, match.start(), match.group())
            for index, line in enumerate(lines)
            if not NOISE.match(line) and '"' not in line
            for match in IDENT.finditer(line)
        ]
        random.shuffle(candidates)
        for line, column, word in candidates[:3]:
            picks.append({"path": path, "line": line, "character": column, "word": word})
    return picks[:count]


def uri(path):
    return "file://" + quote(path)


def percentiles(values):
    if not values:
        return {}
    values = sorted(values)
    at = lambda f: values[min(len(values) - 1, int(len(values) * f))]
    return {
        "count": len(values), "p50_ms": round(at(0.5) * 1000, 3), "p95_ms": round(at(0.95) * 1000, 3),
        "max_ms": round(values[-1] * 1000, 3), "total_s": round(sum(values), 3),
    }


def locations(answer):
    if answer in (None, "timeout") or (isinstance(answer, dict) and "error" in answer):
        return []
    items = answer if isinstance(answer, list) else [answer]
    out = []
    for item in items:
        target = item.get("uri") or item.get("targetUri")
        place = item.get("targetSelectionRange") or item.get("range") or item.get("targetRange")
        if target and place:
            out.append([unquote(target).replace("file://", ""), place["start"]["line"]])
    return out


def run(args, command):
    env = dict(os.environ)
    env["V57_LOCAL"] = "1"
    paths = [path for path in sources(args.root, set(args.ext.split(","))) if not any(part in path for part in args.exclude)]
    picks = sample(paths, args.samples, args.seed)
    results = {"server": command, "root": args.root, "files": len(paths), "phases": {}, "answers": []}
    t0 = time.monotonic()
    server = Server(command, args.root, env)
    capabilities = {
        "general": {"positionEncodings": ["utf-16"]},
        "window": {"workDoneProgress": True},
        "workspace": {"configuration": True, "workspaceFolders": True, "symbol": {}},
        "textDocument": {
            "documentSymbol": {"hierarchicalDocumentSymbolSupport": True}, "definition": {"linkSupport": True},
            "completion": {"completionItem": {"snippetSupport": False}},
        },
    }
    initialized = server.request("initialize", {
        "processId": os.getpid(), "rootUri": uri(args.root), "rootPath": args.root, "capabilities": capabilities,
        "workspaceFolders": [{"uri": uri(args.root), "name": os.path.basename(args.root)}],
    })
    server.notify("initialized", {})
    results["phases"]["initialize_s"] = round(time.monotonic() - t0, 4)
    results["capabilities"] = sorted((initialized or {}).get("capabilities", {}).keys()) if isinstance(initialized, dict) else []

    if args.wait_index:
        waited = server.wait_index(quiet=args.quiet, limit=args.index_limit)
        results["phases"]["index_s"] = None if waited is None else round(waited, 2)
        print(f"indexed in {waited}", file=sys.stderr)
    results["phases"]["ready_s"] = round(time.monotonic() - t0, 3)

    opened = set()
    def open_file(path):
        if path in opened:
            return
        opened.add(path)
        with open(path, encoding="utf-8", errors="replace") as file:
            text = file.read()
        server.notify("textDocument/didOpen", {"textDocument": {
            "uri": uri(path), "languageId": args.language, "version": 1, "text": text}})

    timed = {"documentSymbol": [], "definition": [], "references": [], "hover": [], "completion": [], "workspaceSymbol": []}
    timeouts = 0
    def call(name, method, params, timeout=args.request_timeout):
        nonlocal timeouts
        start = time.monotonic()
        answer = server.request(method, params, timeout=timeout)
        elapsed = time.monotonic() - start
        if answer == "timeout":
            timeouts += 1
        timed[name].append(elapsed)
        return answer

    first = picks[0]["path"] if picks else None
    if first:
        open_file(first)
        start = time.monotonic()
        call("documentSymbol", "textDocument/documentSymbol", {"textDocument": {"uri": uri(first)}})
        results["phases"]["first_document_symbol_s"] = round(time.monotonic() - start, 4)

    for pick in picks:
        open_file(pick["path"])
        document = {"textDocument": {"uri": uri(pick["path"])}}
        position = dict(document, position={"line": pick["line"], "character": pick["character"]})
        definition = call("definition", "textDocument/definition", position)
        record = dict(pick, definition=locations(definition))
        call("documentSymbol", "textDocument/documentSymbol", document)
        call("hover", "textDocument/hover", position)
        if len(timed["references"]) < args.reference_samples:
            references = call(
                "references", "textDocument/references", dict(position, context={"includeDeclaration": True}))
            record["references"] = locations(references)
        if len(timed["completion"]) < args.reference_samples:
            call("completion", "textDocument/completion", position)
        results["answers"].append(record)

    for query in ["Scanner", "highlight", "Language", "run", "view", "Token", "parse", "URL"]:
        answer = call("workspaceSymbol", "workspace/symbol", {"query": query})
        results.setdefault("workspace_symbols", {})[query] = len(answer) if isinstance(answer, list) else str(answer)[:60]

    results["timings"] = {name: percentiles(values) for name, values in timed.items()}
    results["timeouts"] = timeouts
    results["phases"]["total_s"] = round(time.monotonic() - t0, 2)
    results["rss_mb"] = round(server.rss_mb(), 1)
    try:
        server.request("shutdown", None, timeout=10)
        server.notify("exit", None)
        server.process.wait(timeout=10)
    except Exception:
        server.process.kill()
    with open(args.out, "w") as file:
        json.dump(results, file, indent=1)
    summary = {key: results[key] for key in ("phases", "timings", "timeouts", "rss_mb", "workspace_symbols", "files")}
    print(json.dumps(summary, indent=1))


def compare(first_path, second_path):
    """How often the first file's server agrees with the second's (the reference)."""
    first = {(a["path"], a["line"], a["character"]): a for a in json.load(open(first_path))["answers"]}
    second = {(a["path"], a["line"], a["character"]): a for a in json.load(open(second_path))["answers"]}
    both, same_top, contains, reference_empty, first_empty, wrong = 0, 0, 0, 0, 0, []
    recall, precision, reference_sets = [], [], 0
    for key, b in second.items():
        a = first.get(key)
        if a is None:
            continue
        expected = {tuple(x) for x in b["definition"]}
        got = [tuple(x) for x in a["definition"]]
        if not expected:
            reference_empty += 1
            continue
        both += 1
        if not got:
            first_empty += 1
        elif got[0] in expected:
            same_top += 1
        elif expected & set(got):
            contains += 1
        else:
            wrong.append({"at": key, "word": b["word"], "got": got[:2], "expected": sorted(expected)[:2]})
        if "references" in a and "references" in b and b["references"]:
            x, y = {tuple(v) for v in a["references"]}, {tuple(v) for v in b["references"]}
            recall.append(len(x & y) / len(y))
            if x:
                precision.append(len(x & y) / len(x))
            reference_sets += 1
    average = lambda v: round(sum(v) / len(v), 3) if v else None
    print(json.dumps({
        "reference_answered": both, "reference_had_no_answer": reference_empty, "top_match": same_top,
        "in_list_not_first": contains, "no_answer": first_empty, "different": len(wrong),
        "top_match_rate": round(same_top / both, 3) if both else None,
        "any_match_rate": round((same_top + contains) / both, 3) if both else None,
        "references_compared": reference_sets, "references_recall": average(recall),
        "references_precision": average(precision), "sample_different": wrong[:15],
    }, indent=1))


def main():
    arguments = sys.argv[1:]
    command = []
    if "--" in arguments:
        split = arguments.index("--")
        arguments, command = arguments[:split], arguments[split + 1 :]
    parser = argparse.ArgumentParser()
    parser.add_argument("--root")
    parser.add_argument("--out")
    parser.add_argument("--ext", default="swift")
    parser.add_argument("--language", default="swift")
    parser.add_argument("--samples", type=int, default=120)
    parser.add_argument("--reference-samples", type=int, default=25)
    parser.add_argument("--seed", type=int, default=57)
    parser.add_argument("--wait-index", action="store_true")
    parser.add_argument("--quiet", type=float, default=8)
    parser.add_argument("--index-limit", type=float, default=600)
    parser.add_argument("--request-timeout", type=float, default=60)
    parser.add_argument("--compare", nargs=2)
    parser.add_argument("--exclude", action="append", default=[], help="skip sampled paths containing this; keeps positions equal while a tree grows")
    args = parser.parse_args(arguments)
    if args.compare:
        compare(*args.compare)
    else:
        args.root = os.path.realpath(args.root)
        run(args, command)


if __name__ == "__main__":
    main()
