"use client";

import { useFormStatus } from "react-dom";

export function CreateWorkspaceButton() {
  const { pending } = useFormStatus();

  return (
    <button
      aria-busy={pending}
      aria-disabled={pending}
      className="button primary"
      disabled={pending}
      type="submit"
    >
      {pending ? "Creating workspace…" : "Create workspace"}
    </button>
  );
}

