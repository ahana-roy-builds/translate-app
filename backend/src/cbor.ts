import { ApiError } from "./errors.js";

interface Cursor { offset: number; }

function length(buffer: Buffer, cursor: Cursor, additional: number): number {
  if (additional < 24) return additional;
  const bytes = additional === 24 ? 1 : additional === 25 ? 2 : additional === 26 ? 4 : -1;
  if (bytes < 0 || cursor.offset + bytes > buffer.length) throw new ApiError(400, "INVALID_CBOR", "Security object contains invalid CBOR");
  let result = 0;
  for (let index = 0; index < bytes; index += 1) result = result * 256 + buffer[cursor.offset++]!;
  return result;
}

function item(buffer: Buffer, cursor: Cursor, depth: number): unknown {
  if (depth > 16 || cursor.offset >= buffer.length) throw new ApiError(400, "INVALID_CBOR", "Security object contains invalid CBOR");
  const first = buffer[cursor.offset++]!;
  const major = first >> 5, additional = first & 31;
  if (major === 7) {
    if (additional === 20) return false;
    if (additional === 21) return true;
    if (additional === 22) return null;
    throw new ApiError(400, "INVALID_CBOR", "Security object uses unsupported CBOR values");
  }
  const size = length(buffer, cursor, additional);
  if (major === 0) return size;
  if (major === 1) return -1 - size;
  if (major === 2 || major === 3) {
    if (cursor.offset + size > buffer.length) throw new ApiError(400, "INVALID_CBOR", "Security object contains truncated CBOR");
    const value = buffer.subarray(cursor.offset, cursor.offset + size); cursor.offset += size;
    return major === 2 ? Buffer.from(value) : value.toString("utf8");
  }
  if (major === 4) {
    const values: unknown[] = [];
    for (let index = 0; index < size; index += 1) values.push(item(buffer, cursor, depth + 1));
    return values;
  }
  if (major === 5) {
    const values = new Map<unknown, unknown>();
    for (let index = 0; index < size; index += 1) values.set(item(buffer, cursor, depth + 1), item(buffer, cursor, depth + 1));
    return values;
  }
  throw new ApiError(400, "INVALID_CBOR", "Security object uses unsupported CBOR values");
}

export function decodeCBOR(buffer: Buffer): unknown {
  const decoded = decodeCBORPrefix(buffer);
  if (decoded.nextOffset !== buffer.length) throw new ApiError(400, "INVALID_CBOR", "Security object has trailing CBOR data");
  return decoded.value;
}

/** Decode one bounded CBOR value embedded in a larger binary structure. */
export function decodeCBORPrefix(buffer: Buffer, offset = 0): { value: unknown; nextOffset: number } {
  if (!Number.isInteger(offset) || offset < 0 || offset >= buffer.length) throw new ApiError(400, "INVALID_CBOR", "Security object contains invalid CBOR");
  const cursor = { offset };
  const value = item(buffer, cursor, 0);
  return { value, nextOffset: cursor.offset };
}

export function cborMap(value: unknown, code: string): Map<unknown, unknown> {
  if (!(value instanceof Map)) throw new ApiError(400, code, "Security object is malformed");
  return value;
}
