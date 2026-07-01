// Touch-ID gate via WebAuthn — now SERVER-ENFORCED. The server issues a challenge,
// the platform authenticator (Secure Enclave, gated by Touch ID) signs it, and the
// server verifies the ES256 assertion (UV flag + challenge + origin + signCount)
// before minting a short-lived bearer token. The token is what unlocks
// `/api/transactions?amounts=1` — so the amounts are released only after a real,
// verified Touch ID. Works on http://localhost (a WebAuthn secure context).

const CRED_KEY = "millfolio-amounts-cred-id";

function apiBase(): string {
  if (typeof location === "undefined") return "";
  const explicit = new URLSearchParams(location.search).get("api");
  if (explicit) return explicit.replace(/\/$/, "");
  return "";
}

function bufToB64u(buf: ArrayBuffer): string {
  const bytes = new Uint8Array(buf);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64uToBuf(s: string): ArrayBuffer {
  s = s.replace(/-/g, "+").replace(/_/g, "/");
  while (s.length % 4) s += "=";
  const bin = atob(s);
  const buf = new ArrayBuffer(bin.length);
  const view = new Uint8Array(buf);
  for (let i = 0; i < bin.length; i++) view[i] = bin.charCodeAt(i);
  return buf;
}

export function touchIdAvailable(): boolean {
  return (
    typeof window !== "undefined" &&
    typeof PublicKeyCredential !== "undefined" &&
    !!navigator.credentials
  );
}

// One-time enrollment: create a platform passkey (Touch ID) and register its public
// key with the server. The challenge here isn't server-verified (enroll just stores
// the key, trust-on-first-use), so a fresh random challenge is fine.
async function enroll(base: string): Promise<void> {
  const cred = (await navigator.credentials.create({
    publicKey: {
      challenge: crypto.getRandomValues(new Uint8Array(32)),
      rp: { id: location.hostname, name: "Millfolio" },
      user: {
        id: crypto.getRandomValues(new Uint8Array(16)),
        name: "millfolio-amounts",
        displayName: "Millfolio amounts",
      },
      pubKeyCredParams: [{ type: "public-key", alg: -7 }], // ES256
      authenticatorSelection: {
        authenticatorAttachment: "platform",
        userVerification: "required",
        residentKey: "discouraged",
      },
      attestation: "none",
      timeout: 60000,
    },
  })) as PublicKeyCredential | null;
  if (!cred) throw new Error("enrollment cancelled");
  const spki = (cred.response as AuthenticatorAttestationResponse).getPublicKey();
  if (!spki) throw new Error("no public key from authenticator");
  const credId = bufToB64u(cred.rawId);
  localStorage.setItem(CRED_KEY, credId);
  const r = await fetch(`${base}/api/auth/enroll`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ credentialId: credId, publicKey: bufToB64u(spki) }),
  });
  if (!r.ok) throw new Error("enroll rejected by server");
}

// Authenticate: sign the server's challenge (Touch ID) and exchange the assertion
// for a reveal token.
async function verify(base: string): Promise<string> {
  const chResp = await fetch(`${base}/api/auth/challenge`, { method: "POST" });
  const challenge = b64uToBuf((await chResp.json()).challenge);
  const credId = localStorage.getItem(CRED_KEY);
  const assertion = (await navigator.credentials.get({
    publicKey: {
      challenge,
      rpId: location.hostname,
      userVerification: "required",
      allowCredentials: credId ? [{ type: "public-key", id: b64uToBuf(credId) }] : [],
      timeout: 60000,
    },
  })) as PublicKeyCredential | null;
  if (!assertion) throw new Error("Touch ID cancelled");
  const resp = assertion.response as AuthenticatorAssertionResponse;
  const r = await fetch(`${base}/api/auth/verify`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      credentialId: bufToB64u(assertion.rawId),
      authenticatorData: bufToB64u(resp.authenticatorData),
      clientDataJSON: bufToB64u(resp.clientDataJSON),
      signature: bufToB64u(resp.signature),
    }),
  });
  if (!r.ok) throw new Error((await r.json().catch(() => ({}))).error ?? "verification failed");
  return (await r.json()).token as string;
}

// Full unlock ceremony → returns a reveal bearer token, or null on cancel/failure.
export async function unlockAmounts(): Promise<string | null> {
  if (!touchIdAvailable()) return null;
  const base = apiBase();
  try {
    const st = await (await fetch(`${base}/api/auth/status`)).json();
    if (!st.enrolled) await enroll(base);
    return await verify(base);
  } catch {
    return null;
  }
}
