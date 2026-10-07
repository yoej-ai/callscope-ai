export const MAX_AUDIO_SIZE_BYTES = 26_214_400;

export const AUDIO_CONTENT_TYPE_BY_EXTENSION = {
  ".mp3": "audio/mpeg",
  ".mp4": "audio/mp4",
  ".m4a": "audio/x-m4a",
  ".wav": "audio/wav",
  ".webm": "audio/webm",
  ".ogg": "audio/ogg",
} as const;

export type AudioContentType =
  (typeof AUDIO_CONTENT_TYPE_BY_EXTENSION)[keyof typeof AUDIO_CONTENT_TYPE_BY_EXTENSION];

export type ValidAudioFile = {
  contentType: AudioContentType;
  extension: keyof typeof AUDIO_CONTENT_TYPE_BY_EXTENSION;
};

export type AudioFileValidation =
  | { ok: true; value: ValidAudioFile }
  | { ok: false; message: string };

export function validateAudioFileMetadata(
  filename: unknown,
  sizeBytes: unknown,
): AudioFileValidation {
  if (
    typeof filename !== "string" ||
    !filename.trim() ||
    filename.length > 255 ||
    filename.includes("/") ||
    filename.includes("\\") ||
    [...filename].some((character) => character.charCodeAt(0) < 32)
  ) {
    return { ok: false, message: "Choose an audio file with a valid filename." };
  }

  if (
    typeof sizeBytes !== "number" ||
    !Number.isSafeInteger(sizeBytes) ||
    sizeBytes < 1
  ) {
    return { ok: false, message: "Choose a non-empty audio file." };
  }

  if (sizeBytes > MAX_AUDIO_SIZE_BYTES) {
    return { ok: false, message: "The recording must be 25 MiB or smaller." };
  }

  const dotIndex = filename.lastIndexOf(".");
  const extension = filename.slice(dotIndex).toLowerCase();
  if (!(extension in AUDIO_CONTENT_TYPE_BY_EXTENSION)) {
    return {
      ok: false,
      message: "Choose an MP3, MP4 audio, M4A, WAV, WebM, or OGG file.",
    };
  }

  const typedExtension = extension as keyof typeof AUDIO_CONTENT_TYPE_BY_EXTENSION;
  if (filename.length <= typedExtension.length) {
    return { ok: false, message: "Choose an audio file with a valid filename." };
  }

  return {
    ok: true,
    value: {
      contentType: AUDIO_CONTENT_TYPE_BY_EXTENSION[typedExtension],
      extension: typedExtension,
    },
  };
}
