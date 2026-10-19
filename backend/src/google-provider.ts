import { performance } from "node:perf_hooks";
import { ApiError } from "./errors.js";
import { discardResponseBody, readBoundedResponseBody, readBoundedResponseJSON, ResponseBodyTooLargeError } from "./fetch-body.js";
import type { SupportedLocale, TranslateTextInput, TranslateTextResult, TranslateTurnInput, TranslateTurnResult, TranslationProvider } from "./contracts.js";

interface GoogleProviderOptions {
  projectID: string;
  sttLocation: string;
  translationLocation: string;
  speechTimeoutMs: number;
  translationTimeoutMs: number;
}

export interface AccessTokenProvider { getToken(signal?: AbortSignal): Promise<string>; ready(): Promise<boolean>; }

export class MetadataAccessTokenProvider implements AccessTokenProvider {
  private cached?: { value: string; expiresAt: number };
  private inFlight: Promise<string> | undefined;

  private async refresh(): Promise<string> {
    const now = Date.now();
    let response: Response;
    try {
      response = await fetch("http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token", {
        headers: { "Metadata-Flavor": "Google" }, signal: AbortSignal.timeout(3_000)
      });
    } catch { throw new ApiError(503, "GOOGLE_AUTH_UNAVAILABLE", "Translation provider authentication is unavailable"); }
    if (!response.ok) {
      await discardResponseBody(response);
      throw new ApiError(503, "GOOGLE_AUTH_UNAVAILABLE", "Translation provider authentication is unavailable");
    }
    let data: { access_token?: unknown; expires_in?: unknown };
    try { data = await readBoundedResponseJSON(response, 16 * 1024); }
    catch { throw new ApiError(503, "GOOGLE_AUTH_UNAVAILABLE", "Translation provider authentication is unavailable"); }
    if (typeof data.access_token !== "string") throw new ApiError(503, "GOOGLE_AUTH_UNAVAILABLE", "Translation provider authentication is unavailable");
    this.cached = { value: data.access_token, expiresAt: now + (typeof data.expires_in === "number" ? data.expires_in : 300) * 1_000 };
    return data.access_token;
  }

  async getToken(signal?: AbortSignal): Promise<string> {
    if (signal?.aborted) throw new ApiError(499, "UPSTREAM_REQUEST_ABORTED", "The translation request was cancelled");
    const now = Date.now();
    if (this.cached && this.cached.expiresAt > now + 60_000) return this.waitForCaller(Promise.resolve(this.cached.value), signal);
    if (!this.inFlight) {
      const refresh = this.refresh();
      this.inFlight = refresh;
      void refresh.then(
        () => { if (this.inFlight === refresh) this.inFlight = undefined; },
        () => { if (this.inFlight === refresh) this.inFlight = undefined; }
      );
    }
    return this.waitForCaller(this.inFlight, signal);
  }

  private waitForCaller<T>(promise: Promise<T>, signal?: AbortSignal): Promise<T> {
    if (!signal) return promise;
    if (signal.aborted) return Promise.reject(new ApiError(499, "UPSTREAM_REQUEST_ABORTED", "The translation request was cancelled"));
    return new Promise<T>((resolve, reject) => {
      const aborted = () => {
        signal.removeEventListener("abort", aborted);
        reject(new ApiError(499, "UPSTREAM_REQUEST_ABORTED", "The translation request was cancelled"));
      };
      signal.addEventListener("abort", aborted, { once: true });
      promise.then(
        (value) => { signal.removeEventListener("abort", aborted); resolve(value); },
        (error: unknown) => { signal.removeEventListener("abort", aborted); reject(error); }
      );
    });
  }

  async ready(): Promise<boolean> { try { await this.getToken(); return true; } catch { return false; } }
}

async function googleJSON(url: string, body: object, tokens: AccessTokenProvider, timeoutMs: number, outerSignal: AbortSignal): Promise<Record<string, unknown>> {
  const token = await tokens.getToken(outerSignal);
  let response: Response;
  try {
    response = await fetch(url, {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.any([outerSignal, AbortSignal.timeout(timeoutMs)])
    });
  } catch (error) {
    if (outerSignal.aborted) throw new ApiError(499, "UPSTREAM_REQUEST_ABORTED", "The translation request was cancelled");
    if (error instanceof Error && (error.name === "TimeoutError" || error.name === "AbortError")) throw new ApiError(504, "PROVIDER_TIMEOUT", "Online translation timed out");
    throw new ApiError(503, "PROVIDER_UNAVAILABLE", "The online translation provider is temporarily unavailable");
  }
  if (!response.ok) {
    const status = response.status;
    await discardResponseBody(response);
    throw new ApiError(status === 429 ? 503 : 502, "PROVIDER_ERROR", "The online translation provider could not complete the request");
  }
  let bytes: Buffer;
  try {
    bytes = await readBoundedResponseBody(response, 256 * 1024);
  } catch (error) {
    if (error instanceof ApiError) throw error;
    if (error instanceof ResponseBodyTooLargeError) throw new ApiError(502, "PROVIDER_RESPONSE_TOO_LARGE", "The online translation provider returned an invalid response");
    if (outerSignal.aborted) throw new ApiError(499, "UPSTREAM_REQUEST_ABORTED", "The translation request was cancelled");
    if (error instanceof Error && (error.name === "TimeoutError" || error.name === "AbortError")) throw new ApiError(504, "PROVIDER_TIMEOUT", "Online translation timed out");
    throw new ApiError(503, "PROVIDER_UNAVAILABLE", "The online translation provider is temporarily unavailable");
  }
  try {
    const parsed = JSON.parse(bytes.toString("utf8")) as unknown;
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error();
    return parsed as Record<string, unknown>;
  } catch { throw new ApiError(502, "PROVIDER_ERROR", "The online translation provider returned an invalid response"); }
}

function baseLanguage(locale: SupportedLocale): "en" | "es" | "ja" { return locale === "en-US" ? "en" : locale === "es-ES" ? "es" : "ja"; }

export function translationEndpoint(projectID: string, location: string): string {
  return `https://translate-us.googleapis.com/v3/projects/${encodeURIComponent(projectID)}/locations/${encodeURIComponent(location)}:translateText`;
}

function transcript(response: Record<string, unknown>): { text: string; confidence: number | null } {
  const results = Array.isArray(response.results) ? response.results : [];
  const parts: string[] = []; let weighted = 0, weight = 0, missing = false;
  for (const raw of results) {
    if (!raw || typeof raw !== "object") continue;
    const alternatives = Array.isArray((raw as Record<string, unknown>).alternatives) ? (raw as Record<string, unknown>).alternatives as unknown[] : [];
    const first = alternatives[0]; if (!first || typeof first !== "object") continue;
    const candidate = first as Record<string, unknown>;
    if (typeof candidate.transcript !== "string" || !candidate.transcript.trim()) continue;
    const text = candidate.transcript.trim(); parts.push(text);
    if (typeof candidate.confidence === "number" && candidate.confidence >= 0 && candidate.confidence <= 1) {
      weighted += candidate.confidence * text.length; weight += text.length;
    } else missing = true;
  }
  const text = parts.join(" ");
  if (Buffer.byteLength(text, "utf8") > 8_192) throw new ApiError(502, "PROVIDER_RESPONSE_TOO_LARGE", "The online translation provider returned an invalid transcript");
  return { text, confidence: missing || weight === 0 ? null : weighted / weight };
}

function translated(response: Record<string, unknown>): string {
  const item = Array.isArray(response.translations) ? response.translations[0] : undefined;
  const value = item && typeof item === "object" ? (item as Record<string, unknown>).translatedText : undefined;
  if (typeof value !== "string" || !value.trim() || Buffer.byteLength(value, "utf8") > 8_192) throw new ApiError(502, "PROVIDER_ERROR", "The online translation provider returned no valid translation");
  return value.trim();
}

export class GoogleTranslationProvider implements TranslationProvider {
  private readonly options: GoogleProviderOptions;
  private readonly tokens: AccessTokenProvider;
  private readonly circuits = new Map<"speech" | "translation", { failures: number; openUntil: number; failureGeneration: number }>();
  constructor(options: GoogleProviderOptions, tokens: AccessTokenProvider = new MetadataAccessTokenProvider()) { this.options = options; this.tokens = tokens; }

  async ready(): Promise<boolean> {
    const now = Date.now();
    return Boolean(this.options.projectID) && [...this.circuits.values()].every((value) => value.openUntil <= now) && this.tokens.ready();
  }

  private async providerCall<T>(stage: "speech" | "translation", operation: () => Promise<T>): Promise<T> {
    let circuit = this.circuits.get(stage);
    if (!circuit) { circuit = { failures: 0, openUntil: 0, failureGeneration: 0 }; this.circuits.set(stage, circuit); }
    if (circuit.openUntil > Date.now()) throw new ApiError(503, "PROVIDER_CIRCUIT_OPEN", "The online translation provider is temporarily unavailable");
    const admittedFailureGeneration = circuit.failureGeneration;
    try {
      const result = await operation();
      const current = this.circuits.get(stage)!;
      // A success may clear only failures that existed when it was admitted.
      // Otherwise a slow success can resurrect a circuit opened by newer
      // failures that completed while the successful request was in flight.
      if (current.failureGeneration === admittedFailureGeneration) {
        this.circuits.set(stage, { failures: 0, openUntil: 0, failureGeneration: current.failureGeneration });
      }
      return result;
    } catch (error) {
      if (error instanceof ApiError && new Set(["PROVIDER_TIMEOUT", "PROVIDER_UNAVAILABLE", "PROVIDER_ERROR", "PROVIDER_RESPONSE_TOO_LARGE", "GOOGLE_AUTH_UNAVAILABLE"]).has(error.code)) {
        const current = this.circuits.get(stage)!;
        const failures = current.failures + 1;
        this.circuits.set(stage, {
          failures,
          openUntil: failures >= 3 ? Math.max(current.openUntil, Date.now() + 30_000) : current.openUntil,
          failureGeneration: current.failureGeneration + 1
        });
      }
      throw error;
    }
  }

  private async translation(text: string, source: SupportedLocale, target: SupportedLocale, signal: AbortSignal): Promise<{ text: string; milliseconds: number }> {
    const started = performance.now();
    const output = await this.providerCall("translation", async () => translated(await googleJSON(
      translationEndpoint(this.options.projectID, this.options.translationLocation),
      { contents: [text], mimeType: "text/plain", sourceLanguageCode: baseLanguage(source), targetLanguageCode: baseLanguage(target) },
      this.tokens, this.options.translationTimeoutMs, signal
    )));
    return { text: output, milliseconds: Math.round(performance.now() - started) };
  }

  async translateTurn(input: TranslateTurnInput): Promise<TranslateTurnResult> {
    if (!this.options.projectID) throw new ApiError(503, "PROVIDER_NOT_CONFIGURED", "Online translation is not configured");
    const started = performance.now(), location = encodeURIComponent(this.options.sttLocation);
    const recognized = await this.providerCall("speech", async () => transcript(await googleJSON(
      `https://${location}-speech.googleapis.com/v2/projects/${encodeURIComponent(this.options.projectID)}/locations/${location}/recognizers/_:recognize`,
      { config: { explicitDecodingConfig: { encoding: "LINEAR16", sampleRateHertz: 16_000, audioChannelCount: 1 }, languageCodes: [input.sourceLocale], model: "short", features: { enableAutomaticPunctuation: true } }, content: input.audio.subarray(44).toString("base64") },
      this.tokens, this.options.speechTimeoutMs, input.signal
    )));
    const speechRecognition = Math.round(performance.now() - started);
    if (!recognized.text) throw new ApiError(422, "NO_SPEECH_RECOGNIZED", "No speech could be recognized");
    const output = await this.translation(recognized.text, input.sourceLocale, input.targetLocale, input.signal);
    const warnings = recognized.confidence === null || recognized.confidence < 0.70 ? ["uncertainRecognition"] : [];
    return { sourceText: recognized.text, translatedText: output.text, recognitionConfidence: recognized.confidence, engine: "google", warnings, timingsMs: { speechRecognition, translation: output.milliseconds } };
  }

  async translateText(input: TranslateTextInput): Promise<TranslateTextResult> {
    const output = await this.translation(input.text, input.sourceLocale, input.targetLocale, input.signal);
    return { sourceText: input.text, translatedText: output.text, engine: "google", warnings: [], timingsMs: { translation: output.milliseconds } };
  }
}
