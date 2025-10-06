import { createActor } from "../../../declarations/crypto";
import { DerivedPublicKey, IbeCiphertext, IbeIdentity, IbeSeed } from "@dfinity/vetkeys";

function $(id: string): HTMLElement {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Element #${id} not found`);
  return el;
}

function log(msg: string) {
  const logEl = $("log");
  logEl.textContent = `${logEl.textContent ? logEl.textContent + "\n" : ""}${msg}`;
  logEl.scrollTop = logEl.scrollHeight;
}

function randomBytes(len: number): Uint8Array {
  const arr = new Uint8Array(len);
  crypto.getRandomValues(arr);
  return arr;
}

function bytesEq(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

function toHex(u8: Uint8Array, max = 16): string {
  const slice = u8.slice(0, Math.min(max, u8.length));
  return Array.from(slice)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("") + (u8.length > max ? "…" : "");
}

async function main() {
  const runBtn = $("run") as HTMLButtonElement;

  const CANISTER_ID = "6jrls-gqaaa-aaaao-a4pgq-cai";
  const IC_HOST = "https://icp0.io";

  runBtn.onclick = async () => {
    runBtn.disabled = true;
    log(`Starting: canister=${CANISTER_ID}, host=${IC_HOST}`);

    try {
      const actor = createActor(CANISTER_ID, { agentOptions: { host: IC_HOST } });

      const totalBatches = 100;
      const itemsPerBatch = 10;

      const pkBytes = new Uint8Array(await actor.get_ibe_public_key());
      const publicKey = DerivedPublicKey.deserialize(pkBytes);
      const identityStr = Math.floor(Date.now() / 60000).toString();
      const identity = IbeIdentity.fromBytes(new TextEncoder().encode(identityStr));

      const targetPlaintextSize = 256;

      let totalOk = 0;
      let totalNone = 0;
      let totalMismatch = 0;

      const start = Date.now();
      const vetKey = await actor.decrypt_vetkey(identity.getBytes());
      for (let b = 1; b <= totalBatches; b++) {
        const plaintexts: Uint8Array[] = [];
        const chunks: Uint8Array[] = [];
        for (let i = 0; i < itemsPerBatch; i++) {
          const plaintext = randomBytes(targetPlaintextSize);
          const ciphertext = IbeCiphertext.encrypt(publicKey, identity, plaintext, IbeSeed.random()).serialize();
          plaintexts.push(plaintext);
          chunks.push(ciphertext);
        }
        const result = await actor.decrypt_ciphertext(vetKey, chunks);
        const avgSize = Math.round(chunks.reduce((s, c) => s + c.length, 0) / chunks.length);

        let okCount = 0;
        let noneCount = 0;
        let mismatchCount = 0;

        for (let i = 0; i < result.length; i++) {
          const opt: any = result[i];
          const original = plaintexts[i];
          if (Array.isArray(opt) && opt.length === 1) {
            const out = new Uint8Array(opt[0] as any);
            if (bytesEq(out, original)) {
              okCount++;
            } else {
              mismatchCount++;
              if (mismatchCount <= 3) {
                log(`Mismatch in batch ${b} item ${i + 1}: got len=${out.length}, expected len=${original.length} (got=${toHex(out)}, exp=${toHex(original)})`);
              }
            }
          } else {
            noneCount++;
          }
        }
        totalOk += okCount;
        totalNone += noneCount;
        totalMismatch += mismatchCount;
        log(`Batch ${b}/${totalBatches}: sent ${chunks.length} (avg ciphertext ${avgSize} bytes), ok=${okCount}, none=${noneCount}, mismatch=${mismatchCount}`);
      }
      const elapsed = Date.now() - start;
      log(`Completed ${totalBatches} batches in ${elapsed}ms. Totals: ok=${totalOk}, none=${totalNone}, mismatch=${totalMismatch}`);
    } catch (e: any) {
      console.error(e);
      log(`Error: ${e?.message || e}`);
    } finally {
      runBtn.disabled = false;
    }
  };
}

window.addEventListener("DOMContentLoaded", () => {
  main().catch((e) => {
    console.error(e);
    log(`Init error: ${e?.message || e}`);
  });
});
