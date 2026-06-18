"""Veilens app server — SCAFFOLD.

This is a placeholder. The plan (see ../README.md):

  - migrate headgate/src/server.mojo here,
  - import the headgate orchestrator as a library (-I ../../headgate/src ...),
  - replace the single `POST /chat` route with the streaming Veilens protocol:
    status / approval-request / debug / message events (see ../../protocol),
  - bind loopback and expose over Tailscale (`tailscale serve`).

Not yet wired into the build — intentionally trivial so it stays obvious this
is a starting point, not the implementation.
"""


def main():
    print("veilens app server — scaffold; not yet implemented (see README.md)")
