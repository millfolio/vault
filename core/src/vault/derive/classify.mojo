"""Classify — on-device yes/no classification over the chat endpoint (the ML tail).

POSTs to `<base_url>/chat/completions` (OpenAI shape) asking the local model a
yes/no question about each transaction description, BATCHED. Backs the ML category
rules (`<tag> : <question>`) backfilled by `vault.derive.store` at index time.
Local-only (no egress guard); mirrors `vault.index.embed`'s flare wiring. The engine
serves the loaded model regardless of the `model` field, so it's omitted.

Conservative by design: anything the model doesn't clearly mark `yes` is `no`, so
a flaky/garbled reply can't sprinkle false-positive tags onto your transactions.
"""

from flare.http import HttpClient, Request


comptime ML_BATCH = 16  # descriptions per /chat/completions call


def _replace_all(s: String, old: String, new: String) raises -> String:
    var parts = s.split(old)
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += new
        out += String(parts[i])
    return out^


def _json_escape(s: String) raises -> String:
    var o = _replace_all(s, String("\\"), String("\\\\"))
    o = _replace_all(o, String('"'), String('\\"'))
    o = _replace_all(o, String("\n"), String("\\n"))
    o = _replace_all(o, String("\r"), String("\\r"))
    o = _replace_all(o, String("\t"), String("\\t"))
    return o^


def _lower(s: String) -> String:
    var out = String(capacity=s.byte_length() + 1)
    var p = s.unsafe_ptr()
    for i in range(s.byte_length()):
        var c = Int(p[i])
        if c >= 65 and c <= 90:
            out += chr(c + 32)
        else:
            out += chr(c)
    return out^


def _first_int(line: String) -> Int:
    """The first run of ASCII digits in `line` as an Int, or -1 if none (the item
    number the model echoed, e.g. `3` in `3: yes`)."""
    var p = line.unsafe_ptr()
    var i = 0
    var n = line.byte_length()
    while i < n and not (Int(p[i]) >= 48 and Int(p[i]) <= 57):
        i += 1
    if i >= n:
        return -1
    var v = 0
    while i < n and Int(p[i]) >= 48 and Int(p[i]) <= 57:
        v = v * 10 + (Int(p[i]) - 48)
        i += 1
    return v


def classify_batch(
    base_url: String, question: String, descs: List[String]
) raises -> List[Bool]:
    """Ask the on-device model `question` (yes/no) about each description; returns
    one Bool per input, aligned by index. Batches `ML_BATCH` per call. `base_url`
    is the OpenAI-style root, e.g. `http://127.0.0.1:8000/v1`. Raises if the server
    is unreachable or the response isn't the expected chat shape — the caller
    treats that as "skip ML this pass", never as data."""
    var out = List[Bool]()
    if len(descs) == 0:
        return out^
    var client = HttpClient()
    var start = 0
    while start < len(descs):
        var end = start + ML_BATCH
        if end > len(descs):
            end = len(descs)
        var content = String(
            "You label bank-transaction merchants. For each numbered item,"
            " answer this yes/no question using ONLY the merchant text; if"
            " unsure, answer no.\nQUESTION: "
        )
        content += question
        content += (
            "\nReply with one line per item in the form `<number>: yes` or"
            " `<number>: no`, and nothing else.\n\n"
        )
        for j in range(start, end):
            content += String(j - start + 1) + ". " + descs[j] + "\n"

        var body = String(
            '{"max_tokens":512,"messages":[{"role":"user","content":"'
        )
        body += _json_escape(content) + '"}]}'
        var req = Request(
            method="POST",
            url=base_url + "/chat/completions",
            body=List[UInt8](body.as_bytes()),
        )
        req.headers.set("content-type", "application/json")
        var resp = client.send(req)
        var reply: String
        try:
            reply = resp.json()["choices"][0]["message"][
                "content"
            ].string_value()
        except err:
            raise Error(
                "classify: could not parse chat response from "
                + base_url
                + "/chat/completions (is the inference server's chat model"
                " serving?): "
                + String(err)
            )

        # Parse `<n>: yes/no` lines into this batch's verdicts (default no).
        var batch_n = end - start
        var verdict = List[Bool]()
        for _k in range(batch_n):
            verdict.append(False)
        var lines = reply.split("\n")
        for li in range(len(lines)):
            var line = String(lines[li])
            var n = _first_int(line)
            if n >= 1 and n <= batch_n:
                if "yes" in _lower(line):
                    verdict[n - 1] = True
        for k in range(batch_n):
            out.append(verdict[k])
        start = end
    return out^
