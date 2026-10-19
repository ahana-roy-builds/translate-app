export class ApiError extends Error {
  readonly statusCode: number;
  readonly code: string;

  constructor(statusCode: number, code: string, message: string) {
    super(message);
    this.name = "ApiError";
    this.statusCode = statusCode;
    this.code = code;
  }
}

export function asApiError(error: unknown): ApiError {
  if (error instanceof ApiError) return error;
  const candidate = error as { code?: unknown; statusCode?: unknown };
  if (candidate?.code === "FST_ERR_CTP_BODY_TOO_LARGE" || candidate?.statusCode === 413) {
    return new ApiError(413, "PAYLOAD_TOO_LARGE", "Request payload exceeds the permitted size");
  }
  if (candidate?.code === "FST_ERR_CTP_INVALID_MEDIA_TYPE" || candidate?.statusCode === 415) {
    return new ApiError(415, "UNSUPPORTED_MEDIA_TYPE", "Request Content-Type is unsupported");
  }
  if (typeof candidate?.statusCode === "number" && candidate.statusCode >= 400 && candidate.statusCode < 500) {
    return new ApiError(candidate.statusCode, "INVALID_REQUEST", "Request is invalid");
  }
  return new ApiError(500, "INTERNAL_ERROR", "The request could not be completed");
}
