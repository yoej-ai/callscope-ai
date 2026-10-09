"use client";

import { useEffect } from "react";
import { useRouter } from "next/navigation";

type CallStatusAutoRefreshProps = {
  active: boolean;
  intervalMs?: number;
};

export function CallStatusAutoRefresh({
  active,
  intervalMs = 5000,
}: CallStatusAutoRefreshProps) {
  const router = useRouter();

  useEffect(() => {
    if (!active) return;

    const timer = window.setInterval(() => {
      if (document.visibilityState === "visible") {
        router.refresh();
      }
    }, intervalMs);

    return () => {
      window.clearInterval(timer);
    };
  }, [active, intervalMs, router]);

  return null;
}
