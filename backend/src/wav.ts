import { ApiError } from "./errors.js";

export interface ParsedWav {
  durationMs: number;
  pcmBytes: number;
}

/** Accept only the canonical iOS interchange format; provider input length is authoritative. */
export function parseCanonicalPCM16Wav(audio: Buffer, maximumBytes = 960_044): ParsedWav {
  if (audio.length > maximumBytes) throw new ApiError(413, "AUDIO_TOO_LARGE", "Audio exceeds the 30-second upload limit");
  if (audio.length < 46) throw new ApiError(400, "INVALID_WAV", "Audio must contain canonical PCM WAV data");
  if (audio.toString("ascii", 0, 4) !== "RIFF" || audio.toString("ascii", 8, 12) !== "WAVE") {
    throw new ApiError(400, "INVALID_WAV", "Audio must be a RIFF/WAVE file");
  }
  if (audio.readUInt32LE(4) !== audio.length - 8) throw new ApiError(400, "INVALID_WAV", "WAV RIFF length does not match the request body");
  if (audio.toString("ascii", 12, 16) !== "fmt " || audio.readUInt32LE(16) !== 16) {
    throw new ApiError(400, "INVALID_WAV", "WAV must have a canonical 16-byte format chunk");
  }
  if (audio.readUInt16LE(20) !== 1 || audio.readUInt16LE(22) !== 1 || audio.readUInt32LE(24) !== 16_000 ||
      audio.readUInt32LE(28) !== 32_000 || audio.readUInt16LE(32) !== 2 || audio.readUInt16LE(34) !== 16) {
    throw new ApiError(400, "UNSUPPORTED_WAV_FORMAT", "WAV must be mono 16 kHz signed 16-bit PCM");
  }
  if (audio.toString("ascii", 36, 40) !== "data") throw new ApiError(400, "INVALID_WAV", "WAV must have a canonical data chunk");
  const pcmBytes = audio.readUInt32LE(40);
  if (pcmBytes !== audio.length - 44 || pcmBytes === 0 || pcmBytes % 2 !== 0) {
    throw new ApiError(400, "INVALID_WAV", "WAV data length is invalid");
  }
  if (pcmBytes > 960_000) throw new ApiError(413, "AUDIO_TOO_LONG", "Audio must not exceed 30 seconds");
  return { durationMs: pcmBytes / 32, pcmBytes };
}
