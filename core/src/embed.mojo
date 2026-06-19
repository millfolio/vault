"""Embed — HTTP client for the local inference-server embeddings endpoint.

POSTs to `POST <base_url>/embeddings` (OpenAI shape) with `{"input": <text>}` and
parses `{"data":[{"embedding":[...]}]}` into a `List[Float32]`. Mirrors
headgate/src/transport.mojo's LocalClient flare wiring; local-only, no egress
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
