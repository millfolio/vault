// Client-side Touch-ID gate via WebAuthn platform authenticator. Used to reveal the
// masked transaction amounts. This is a PRIVACY SCREEN, not a cryptographic boundary:
// the server withholds the amounts until the client asks (after Touch ID), but the
// challenge is generated locally and the assertion isn't verified server-side — fine
// for a single-user local app on http://localhost (a secure context for WebAuthn).
//
// First unlock enrolls a platform passkey (which itself requires Touch ID); later
// unlocks authenticate against it. The credential id is remembered per browser.

const KEY = "millfolio-amounts-passkey-id";

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

// Prompt Touch ID (enrolling a platform passkey on first use). Returns true on a
// successful user verification, false on cancel / unavailable / error.
export async function unlockWithTouchId(): Promise<boolean> {
  if (!touchIdAvailable()) return false;
  const rpId = location.hostname; // "localhost" (or a Tailscale host)
  const challenge = crypto.getRandomValues(new Uint8Array(32));
  const stored = localStorage.getItem(KEY);
  try {
    if (stored) {
      await navigator.credentials.get({
        publicKey: {
          challenge,
          rpId,
          allowCredentials: [{ type: "public-key", id: b64uToBuf(stored) }],
          userVerification: "required",
          timeout: 60000,
        },
      });
      return true;
    }
    const cred = (await navigator.credentials.create({
      publicKey: {
        challenge,
        rp: { id: rpId, name: "Millfolio" },
        user: {
          id: crypto.getRandomValues(new Uint8Array(16)),
          name: "millfolio-amounts",
          displayName: "Millfolio amounts",
        },
        pubKeyCredParams: [
          { type: "public-key", alg: -7 }, // ES256
          { type: "public-key", alg: -257 }, // RS256
        ],
        authenticatorSelection: {
          authenticatorAttachment: "platform",
          userVerification: "required",
          residentKey: "discouraged",
        },
        attestation: "none",
        timeout: 60000,
      },
    })) as PublicKeyCredential | null;
    if (cred) localStorage.setItem(KEY, bufToB64u(cred.rawId));
    return !!cred;
  } catch {
    return false; // user cancelled, no biometric enrolled, or an error
  }
}
