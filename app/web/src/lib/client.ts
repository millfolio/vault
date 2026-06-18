// Mock Veilens client — drives the UI without a backend yet. It simulates the
// server streaming the vault workflow (alias manifest → ask model → approval
// gate → compile → run → answer), including a debug payload per step and one
// approval gate. Swap this for a real transport (WebSocket/SSE to the Mojo
// `server/` over Tailscale) implementing the same VeilensClient interface.

import type { ServerEvent, Session, VeilensClient } from "./protocol";

let seq = 0;
const uid = (p: string) => `${p}-${++seq}`;

const SAMPLE_PROGRAM = `from vault import *

def main():
    # aliased columns only — never the real data
    rows = search("oldest transaction", k=5)
    print(rows.min_by("date_col_0"))`;

class MockSession implements Session {
  private gate?: (ok: boolean, reason?: string) => void;

  constructor(
    private text: string,
    private onEvent: (e: ServerEvent) => void,
  ) {
    void this.run();
  }

  approve(_stepId: string) {
    this.gate?.(true);
    this.gate = undefined;
  }
  reject(_stepId: string, reason?: string) {
    this.gate?.(false, reason);
    this.gate = undefined;
  }

  private wait(ms: number) {
    return new Promise<void>((r) => setTimeout(r, ms));
  }
  private awaitGate() {
    return new Promise<{ ok: boolean; reason?: string }>((resolve) => {
      this.gate = (ok, reason) => resolve({ ok, reason });
    });
  }

  private async run() {
    const emit = this.onEvent;

    const manifest = uid("manifest");
    emit({ type: "status", stepId: manifest, label: "Aliasing vault manifest", state: "running" });
    await this.wait(600);
    emit({ type: "debug", stepId: manifest, title: "Frontier-safe manifest (aliases only)", body: "file_0  col_0:date  col_1:amount  col_2:merchant\nfile_1  col_0:date  col_1:balance", language: "text" });
    emit({ type: "status", stepId: manifest, label: "Aliasing vault manifest", state: "done" });

    const gen = uid("codegen");
    emit({ type: "status", stepId: gen, label: "Asking the model to write a program", state: "running" });
    await this.wait(800);
    emit({ type: "debug", stepId: gen, title: "Generated program", body: SAMPLE_PROGRAM, language: "mojo" });
    emit({ type: "status", stepId: gen, label: "Asking the model to write a program", state: "done" });

    // Approval gate.
    const run = uid("run");
    emit({ type: "status", stepId: run, label: "Run the generated program over your vault?", state: "awaiting-approval" });
    emit({
      type: "approval-request",
      stepId: run,
      label: "Run the generated program over your vault?",
      payload: { title: "Sandboxed run — reads your real data locally, no network", body: SAMPLE_PROGRAM, language: "mojo" },
    });
    const { ok, reason } = await this.awaitGate();
    if (!ok) {
      emit({ type: "status", stepId: run, label: "Run rejected", state: "error", detail: reason });
      emit({ type: "message", id: uid("msg"), role: "assistant", text: "Okay — I won't run that. Tell me how you'd like to adjust it." });
      return;
    }

    emit({ type: "status", stepId: run, label: "Compiling & running in sandbox", state: "running" });
    await this.wait(900);
    emit({ type: "debug", stepId: run, title: "Sandbox stdout", body: "2024-01-03  -42.10  Corner Market", language: "text" });
    emit({ type: "status", stepId: run, label: "Compiling & running in sandbox", state: "done" });

    emit({ type: "message", id: uid("msg"), role: "assistant", text: `Your oldest transaction is from 2024-01-03: $42.10 at Corner Market. (Asked: "${this.text}")` });
  }
}

export function createMockClient(): VeilensClient {
  return {
    ask(text, onEvent) {
      return new MockSession(text, onEvent);
    },
  };
}
