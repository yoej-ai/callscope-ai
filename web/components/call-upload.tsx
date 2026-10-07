"use client";

import { useRef, useState } from "react";
import { useRouter } from "next/navigation";

import { validateAudioFileMetadata } from "@/lib/audio-files";
import { createClient } from "@/lib/supabase/client";

type CallUploadProps = {
  workspaceId: string;
};

type UploadStage =
  | "ready"
  | "preparing"
  | "uploading"
  | "verifying"
  | "complete"
  | "error";

type SignedUpload = {
  call_id: string;
  bucket: "call-audio";
  path: string;
  upload_token: string;
  expires_in_seconds: number;
};

class UploadFlowError extends Error {}

const STAGE_MESSAGE: Record<UploadStage, string> = {
  ready: "Ready",
  preparing: "Preparing secure upload…",
  uploading: "Uploading recording…",
  verifying: "Verifying upload…",
  complete: "Upload complete",
  error: "Upload needs attention",
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isUuid(value: unknown): value is string {
  return (
    typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      value,
    )
  );
}

function parseSignedUpload(
  value: unknown,
  workspaceId: string,
): SignedUpload | null {
  if (
    !isRecord(value) ||
    Object.keys(value).sort().join(",") !==
      "bucket,call_id,expires_in_seconds,path,upload_token" ||
    !isUuid(value.call_id) ||
    value.bucket !== "call-audio" ||
    typeof value.path !== "string" ||
    typeof value.upload_token !== "string" ||
    !value.upload_token ||
    value.upload_token.length > 8192 ||
    /[\u0000-\u001f\u007f]/.test(value.upload_token) ||
    value.expires_in_seconds !== 7200
  ) {
    return null;
  }

  const segments = value.path.split("/");
  if (
    segments.length !== 3 ||
    segments[0] !== workspaceId ||
    segments[1] !== value.call_id ||
    !/^source\.(mp3|mp4|m4a|wav|webm|ogg)$/.test(segments[2])
  ) {
    return null;
  }

  return {
    call_id: value.call_id,
    bucket: value.bucket,
    path: value.path,
    upload_token: value.upload_token,
    expires_in_seconds: value.expires_in_seconds,
  };
}

function isCompletedUpload(value: unknown, callId: string) {
  return (
    isRecord(value) &&
    Object.keys(value).sort().join(",") === "call_id,status" &&
    value.call_id === callId &&
    value.status === "uploaded"
  );
}

function routeError(status: number, fallback: string, notFoundMessage: string) {
  if (status === 401) {
    return "Your session has expired. Sign in again before retrying.";
  }
  if (status === 404) {
    return notFoundMessage;
  }
  return fallback;
}

export function CallUpload({ workspaceId }: CallUploadProps) {
  const router = useRouter();
  const fileInput = useRef<HTMLInputElement>(null);
  const working = useRef(false);
  const [stage, setStage] = useState<UploadStage>("ready");
  const [message, setMessage] = useState(STAGE_MESSAGE.ready);
  const isWorking = ["preparing", "uploading", "verifying"].includes(stage);

  async function handleSubmit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (working.current) return;

    const file = fileInput.current?.files?.[0];
    if (!file) {
      setStage("error");
      setMessage("Choose a call recording to upload.");
      return;
    }

    const validation = validateAudioFileMetadata(file.name, file.size);
    if (!validation.ok) {
      setStage("error");
      setMessage(validation.message);
      return;
    }

    let storageUploaded = false;
    working.current = true;
    try {
      setStage("preparing");
      setMessage(STAGE_MESSAGE.preparing);
      const initiateResponse = await fetch(
        `/api/workspaces/${encodeURIComponent(workspaceId)}/calls/uploads`,
        {
          method: "POST",
          cache: "no-store",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            filename: file.name,
            content_type: validation.value.contentType,
            size_bytes: file.size,
          }),
        },
      );

      if (!initiateResponse.ok) {
        throw new UploadFlowError(
          routeError(
            initiateResponse.status,
            "Could not prepare the secure upload. Please try again.",
            "This workspace is no longer available.",
          ),
        );
      }

      const upload = parseSignedUpload(
        await initiateResponse.json(),
        workspaceId,
      );
      if (!upload) {
        throw new UploadFlowError(
          "Could not prepare the secure upload. Please try again.",
        );
      }

      setStage("uploading");
      setMessage(STAGE_MESSAGE.uploading);
      const canonicalFile = new File([file], file.name, {
        type: validation.value.contentType,
        lastModified: file.lastModified,
      });
      const supabase = createClient();
      const { data: storedObject, error: storageError } = await supabase.storage
        .from(upload.bucket)
        .uploadToSignedUrl(upload.path, upload.upload_token, canonicalFile, {
          contentType: validation.value.contentType,
          upsert: false,
        });

      if (storageError || storedObject?.path !== upload.path) {
        throw new UploadFlowError(
          "Upload failed. Please choose the file and try again.",
        );
      }
      storageUploaded = true;

      setStage("verifying");
      setMessage(STAGE_MESSAGE.verifying);
      const completeResponse = await fetch(
        `/api/workspaces/${encodeURIComponent(workspaceId)}/calls/${encodeURIComponent(upload.call_id)}/complete`,
        {
          method: "POST",
          cache: "no-store",
          headers: { "Content-Type": "application/json" },
          body: "{}",
        },
      );

      if (!completeResponse.ok) {
        throw new UploadFlowError(
          routeError(
            completeResponse.status,
            "The recording uploaded, but it could not be verified. Please refresh and try again later.",
            "The recording uploaded, but the call could not be finalized.",
          ),
        );
      }

      const completion: unknown = await completeResponse.json();
      if (!isCompletedUpload(completion, upload.call_id)) {
        throw new UploadFlowError(
          "The recording uploaded, but it could not be verified. Please refresh and try again later.",
        );
      }

      if (fileInput.current) fileInput.current.value = "";
      setStage("complete");
      setMessage(STAGE_MESSAGE.complete);
      router.refresh();
    } catch (error) {
      setStage("error");
      setMessage(
        error instanceof UploadFlowError
          ? error.message
          : storageUploaded
            ? "The recording uploaded, but it could not be verified. Please refresh and try again later."
            : "Upload failed. Please choose the file and try again.",
      );
    } finally {
      working.current = false;
    }
  }

  return (
    <section className="upload-card" aria-labelledby="upload-title">
      <div>
        <p className="eyebrow">Private ingestion</p>
        <h2 id="upload-title">Upload a call recording</h2>
        <p className="upload-guidance">
          MP3, MP4 audio, M4A, WAV, WebM, or OGG · 25 MiB maximum
        </p>
      </div>
      <form className="upload-form" onSubmit={handleSubmit}>
        <label htmlFor="call-recording">Recording</label>
        <input
          accept=".mp3,.mp4,.m4a,.wav,.webm,.ogg,audio/mpeg,audio/mp4,audio/x-m4a,audio/wav,audio/webm,audio/ogg"
          disabled={isWorking}
          id="call-recording"
          name="recording"
          ref={fileInput}
          type="file"
        />
        <button className="button primary" disabled={isWorking} type="submit">
          {isWorking ? "Working…" : "Upload recording"}
        </button>
      </form>
      <div
        aria-live="polite"
        className={`upload-status ${stage}`}
        role="status"
      >
        {isWorking && <span className="status-pulse" aria-hidden="true" />}
        <span>{message}</span>
      </div>
    </section>
  );
}
