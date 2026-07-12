// Amount-reveal gate via a local passphrase. The server holds the secret
// (`amount_password` in the data dir — look it up with `mill get amount-password`)
// and, on a correct match, mints a short-lived bearer token. That token is what
// unlocks `/api/transactions?amounts=1`, so the gate is genuinely server-enforced:
// no token → amounts stay masked, even for a raw curl.

function apiBase(): string {
  if (typeof location === "undefined") return "";
  const explicit = new URLSearchParams(location.search).get("api");
  if (explicit) return explicit.replace(/\/$/, "");
  return "";
}

// Exchange the passphrase for a reveal token. Resolves with the token on success;
// throws with a user-facing message on a wrong passphrase or a network error.
export async function unlockAmounts(password: string): Promise<string> {
  const r = await fetch(`${apiBase()}/api/auth/unlock`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ password }),
  });
  if (r.status === 401) throw new Error("Wrong passphrase — try again.");
  if (!r.ok) throw new Error("Unlock failed. Is millfolio running?");
  const token = (await r.json()).token as string | undefined;
  if (!token) throw new Error("Unlock failed.");
  return token;
}

// The native macOS app hosts this web UI in a WKWebView and exposes a bridge at
// `window.webkit.messageHandlers.millfolio`. Its presence is how we know we can
// offer native Touch-ID unlock (an older app build without the `unlockAmounts`
// handler still has the bridge, but simply never calls our callback → the promise
// times out and we fall back to the passphrase). In a plain browser this is false.
export function hasNativeBridge(): boolean {
  if (typeof window === "undefined") return false;
  const w = window as unknown as {
    webkit?: { messageHandlers?: { millfolio?: unknown } };
  };
  return !!w.webkit?.messageHandlers?.millfolio;
}

// Native Touch-ID unlock. Registers the global callbacks the native app invokes,
// posts `{type:"unlockAmounts"}` across the bridge, and resolves with the reveal
// token on success. The native side: runs `LAContext.evaluatePolicy(
// .deviceOwnerAuthentication)` (Touch ID / Apple Watch / login password), on
// success reads the local `.reveal-secret` and POSTs it to
// `/api/amounts/unlock-local` to mint the SAME token the passphrase path mints,
// then calls `window.__millfolioReveal(token)` — or `window.__millfolioRevealFailed(msg)`
// on cancel/failure. A `timeoutMs` guards a native build too old to answer, so the
// caller can degrade to the passphrase flow.
export function unlockAmountsNative(timeoutMs = 60000): Promise<string> {
  return new Promise((resolve, reject) => {
    if (!hasNativeBridge()) {
      reject(new Error("Native unlock isn't available here."));
      return;
    }
    const w = window as unknown as {
      webkit: { messageHandlers: { millfolio: { postMessage: (m: unknown) => void } } };
      __millfolioReveal?: (token: string) => void;
      __millfolioRevealFailed?: (msg?: string) => void;
    };
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const cleanup = () => {
      if (timer !== undefined) clearTimeout(timer);
      delete w.__millfolioReveal;
      delete w.__millfolioRevealFailed;
    };
    w.__millfolioReveal = (token: string) => {
      if (settled) return;
      settled = true;
      cleanup();
      if (token) resolve(token);
      else reject(new Error("Unlock failed."));
    };
    w.__millfolioRevealFailed = (msg?: string) => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(new Error(msg || "Touch ID was cancelled."));
    };
    timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      cleanup();
      reject(new Error("Touch ID didn't respond — try a passphrase."));
    }, timeoutMs);
    try {
      w.webkit.messageHandlers.millfolio.postMessage({ type: "unlockAmounts" });
    } catch {
      if (!settled) {
        settled = true;
        cleanup();
        reject(new Error("Couldn't reach the native app."));
      }
    }
  });
}
