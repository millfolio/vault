"""Embed — HTTP client for the local inference-server embeddings endpoint.

POSTs to `POST <base_url>/embeddings` (OpenAI shape) with `{"input": <text>}` and
parses `{"data":[{"embedding":[...]}]}` into a `List[Float32]`. Mirrors
privacy_box/src/transport.mojo's LocalClient flare wiring; local-only, no egress
guard.

The embedding model is Qwen3-Embedding-0.6B -> dim 1024. This is the CLIENT side:
the server endpoint is being built in parallel and may not be live yet — a failed
request surfaces as a clear Error.
"""

from flare.http import HttpClient, Request


comptime EMBED_DIM = 1024


def _replace_all(s: String, old: String, new: String) raises -> String:
    var parts = s.split(old)
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += new
        out += String(parts[i])
    return out^


def _json_escape(s: String) raises -> String:
    """Escape a String for embedding in a JSON string literal."""
    var o = _replace_all(s, String("\\"), String("\\\\"))
    o = _replace_all(o, String('"'), String('\\"'))
    o = _replace_all(o, String("\n"), String("\\n"))
    o = _replace_all(o, String("\r"), String("\\r"))
    o = _replace_all(o, String("\t"), String("\\t"))
    return o^


def embed(base_url: String, text: String) raises -> List[Float32]:
    """Embed `text` via the local inference-server.

    `base_url` is the OpenAI-style root, e.g. `http://127.0.0.1:8000/v1`. POSTs
    `{"input": "..."}` to `<base_url>/embeddings` and returns the first embedding
    vector. Raises a clear error if the server is unreachable or the response
    isn't the expected `{"data":[{"embedding":[...]}]}` shape (e.g. the embeddings
    endpoint isn't serving yet).
    """
    var body = String('{"input":"') + _json_escape(text) + '"}'
    var req = Request(
        method="POST",
        url=base_url + "/embeddings",
        body=List[UInt8](body.as_bytes()),
    )
    req.headers.set("content-type", "application/json")
    var client = HttpClient()
    var resp = client.send(req)

    var vec = List[Float32]()
    try:
        var arr = resp.json()["data"][0]["embedding"]
        var n = arr.array_count()
        for i in range(n):
            vec.append(Float32(arr[i].float_value()))
    except err:
        raise Error(
            "embed: could not parse embeddings response from "
            + base_url
            + "/embeddings (is the inference-server embedding model serving?): "
            + String(err)
        )
    if len(vec) == 0:
        raise Error("embed: empty embedding returned from " + base_url)
    return vec^


def embed_batch(
    base_url: String, texts: List[String]
) raises -> List[List[Float32]]:
    """Embed many texts in ONE request and return one vector per input, in order.

    POSTs `{"input":[...]}` (the OpenAI array form the server already supports) to
    `<base_url>/embeddings` and parses every `data[i].embedding`. This is the
    indexing fast path: it collapses N per-chunk round-trips (and N fresh
    connections) into one request per batch — the single-GPU server still embeds
    each input, but the network/connection/parse overhead is amortized. Raises if
    the server is unreachable, the shape is unexpected, or the count mismatches.
    """
    if len(texts) == 0:
        return List[List[Float32]]()
    var body = String('{"input":[')
    for i in range(len(texts)):
        if i > 0:
            body += ","
        body += String('"') + _json_escape(texts[i]) + '"'
    body += "]}"
    var req = Request(
        method="POST",
        url=base_url + "/embeddings",
        body=List[UInt8](body.as_bytes()),
    )
    req.headers.set("content-type", "application/json")
    var client = HttpClient()
    var resp = client.send(req)

    var out = List[List[Float32]]()
    try:
        # Backfill each array ONCE via array_items() — O(n). Indexing the lazy
        # value (`data[i]`, `arr[j]`) instead re-traverses per access, which is
        # O(n^2) on a large batched response (358 KB for 28 chunks → 20s+ at 100% CPU).
        var data = resp.json()["data"].array_items()
        for i in range(len(data)):
            var arr = data[i]["embedding"].array_items()
            var vec = List[Float32]()
            for j in range(len(arr)):
                vec.append(Float32(arr[j].float_value()))
            out.append(vec^)
    except err:
        raise Error(
            "embed_batch: could not parse embeddings response from "
            + base_url
            + "/embeddings (is the inference-server embedding model serving?): "
            + String(err)
        )
    if len(out) != len(texts):
        raise Error(
            "embed_batch: server returned "
            + String(len(out))
            + " embeddings for "
            + String(len(texts))
            + " inputs"
        )
    return out^
