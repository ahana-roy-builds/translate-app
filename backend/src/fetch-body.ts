export class ResponseBodyTooLargeError extends Error {
  constructor() { super("response body exceeds its limit"); this.name = "ResponseBodyTooLargeError"; }
}

async function cancel(reader: ReadableStreamDefaultReader<Uint8Array> | undefined, response: Response): Promise<void> {
  try {
    if (reader) await reader.cancel();
    else await response.body?.cancel();
  } catch { /* The connection is already unusable; preserve the primary error. */ }
}

export async function readBoundedResponseBody(response: Response, maximumBytes: number): Promise<Buffer> {
  const declared = response.headers.get("content-length");
  if (declared !== null && (!/^\d+$/.test(declared) || Number(declared) > maximumBytes)) {
    await cancel(undefined, response);
    throw new ResponseBodyTooLargeError();
  }
  if (!response.body) return Buffer.alloc(0);
  const reader = response.body.getReader();
  const chunks: Buffer[] = [];
  let total = 0;
  try {
    while (true) {
      const part = await reader.read();
      if (part.done) break;
      total += part.value.byteLength;
      if (total > maximumBytes) {
        await cancel(reader, response);
        throw new ResponseBodyTooLargeError();
      }
      chunks.push(Buffer.from(part.value));
    }
    return Buffer.concat(chunks, total);
  } catch (error) {
    await cancel(reader, response);
    throw error;
  }
}

export async function readBoundedResponseJSON<T>(response: Response, maximumBytes: number): Promise<T> {
  return JSON.parse((await readBoundedResponseBody(response, maximumBytes)).toString("utf8")) as T;
}

/** Drain a small response for connection reuse and cancel deterministically if it is larger or broken. */
export async function discardResponseBody(response: Response, maximumBytes = 64 * 1024): Promise<void> {
  try { await readBoundedResponseBody(response, maximumBytes); }
  catch { try { await response.body?.cancel(); } catch { /* best effort */ } }
}
