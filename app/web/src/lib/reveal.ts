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
